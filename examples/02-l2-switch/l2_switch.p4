/*
 * examples/02-l2-switch/l2_switch.p4
 *
 * 基于目的 MAC 做精确匹配的 L2 静态转发交换机。
 * 目的 MAC 未知时广播到所有端口（粗糙的 flood，仅用于教学）。
 *
 * 编译:  ./build.sh
 * 运行:  sudo ./run.sh
 */

#include <core.p4>
#include <v1model.p4>

/* ===== 类型 ===== */
typedef bit<48> mac_t;
typedef bit<9>  port_t;

const bit<16> TYPE_IPV4 = 0x0800;

header ethernet_t {
    mac_t   dst;
    mac_t   src;
    bit<16> etherType;
}

struct headers  { ethernet_t ethernet; }
struct metadata { }

/* ===== Parser ===== */
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t std) {
    state start {
        packet.extract(hdr.ethernet);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/* ===== Ingress ===== */
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t std) {

    action drop()                    { mark_to_drop(std); }
    action forward(port_t port)      { std.egress_spec = port; }
    action broadcast(bit<16> mcast)  { std.mcast_grp = mcast; }

    table dmac {
        key = { hdr.ethernet.dst : exact; }
        actions = { forward; broadcast; drop; NoAction; }
        size = 4096;
        default_action = NoAction;
    }

    apply {
        if (hdr.ethernet.isValid()) {
            if (!dmac.apply().hit) {
                // 未命中 = 未学到，广播（控制平面预先配好 mcast_grp=1）
                broadcast(1);
            }
        }
    }
}

/* ===== Egress：防止广播回源端口 ===== */
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std) {
    apply {
        if (std.egress_port == std.ingress_port) {
            mark_to_drop(std);
        }
    }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr.ethernet); }
}

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
