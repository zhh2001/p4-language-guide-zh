/*
 * examples/04-acl/acl.p4
 *
 * 基于 5-tuple 的三元组 ACL：
 *   - 用 ternary 匹配做灵活的 permit/deny
 *   - 附带 direct_counter 统计每条规则命中情况
 *
 * 在 IPv4 router 之上加一层 ACL，演示复合表的典型用法。
 */

#include <core.p4>
#include <v1model.p4>

typedef bit<48> mac_t;
typedef bit<32> ipv4_t;
typedef bit<9>  port_t;

const bit<16> TYPE_IPV4 = 0x0800;
const bit<8>  PROTO_TCP = 6;
const bit<8>  PROTO_UDP = 17;

header ethernet_h {
    mac_t dst;
    mac_t src;
    bit<16> etherType;
}
header ipv4_h {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    ipv4_t  src;
    ipv4_t  dst;
}
header l4_ports_h {
    bit<16> src;
    bit<16> dst;
}

struct headers {
    ethernet_h ethernet;
    ipv4_h     ipv4;
    l4_ports_h l4;
}
struct metadata { }

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t std) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP: parse_l4;
            PROTO_UDP: parse_l4;
            default:   accept;
        }
    }
    state parse_l4 {
        packet.extract(hdr.l4);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t std) {

    direct_counter(CounterType.packets_and_bytes) acl_ctr;

    action permit()         { acl_ctr.count(); }
    action deny()           { mark_to_drop(std); acl_ctr.count(); }

    action forward(port_t port) { std.egress_spec = port; }
    action drop() { mark_to_drop(std); }

    // 1. 简单 L2 转发（只为了能出包；真实系统会是更复杂的 L3）
    table l2 {
        key = { hdr.ethernet.dst : exact; }
        actions = { forward; drop; NoAction; }
        default_action = drop;
    }

    // 2. 三元组 ACL
    table acl {
        key = {
            hdr.ipv4.src      : ternary;
            hdr.ipv4.dst      : ternary;
            hdr.ipv4.protocol : ternary;
            hdr.l4.src        : ternary;
            hdr.l4.dst        : ternary;
        }
        actions  = { permit; deny; NoAction; }
        counters = acl_ctr;
        size = 1024;
        default_action = permit;    // 缺省放行
    }

    apply {
        if (hdr.ipv4.isValid()) {
            switch (acl.apply().action_run) {
                deny: { return; }   // 已丢弃，退出
            }
        }
        l2.apply();
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std) {
    apply { }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.l4);
    }
}

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
