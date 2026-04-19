/*
 * examples/03-ipv4-router/router.p4
 *
 * IPv4 路由器：
 *   - LPM 匹配目的 IPv4 → 输出端口 + 下一跳 IP
 *   - 改写目的 MAC 为下一跳的 MAC（通过 arp 表查询）
 *   - 改写源 MAC 为交换机出端口的 MAC
 *   - TTL - 1，若为 0 丢弃
 *   - 重新计算 IPv4 校验和
 */

#include <core.p4>
#include <v1model.p4>

/* ===== 类型 ===== */
typedef bit<48> mac_t;
typedef bit<32> ipv4_t;
typedef bit<9>  port_t;

const bit<16> TYPE_IPV4 = 0x0800;

header ethernet_h {
    mac_t   dst;
    mac_t   src;
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

struct headers {
    ethernet_h ethernet;
    ipv4_h     ipv4;
}

struct metadata {
    ipv4_t nextHop;   // 路由查到的下一跳 IP
}

/* ===== Parser ===== */
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
        transition accept;
    }
}

/* ===== 入方向校验和 ===== */
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

/* ===== Ingress ===== */
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t std) {

    action drop() { mark_to_drop(std); }

    action set_nhop(ipv4_t nh_ip, port_t out_port) {
        meta.nextHop      = nh_ip;
        std.egress_spec   = out_port;
        hdr.ipv4.ttl      = hdr.ipv4.ttl - 1;
    }

    action rewrite_src_mac(mac_t src) { hdr.ethernet.src = src; }
    action rewrite_dst_mac(mac_t dst) { hdr.ethernet.dst = dst; }

    // 1. 路由表（LPM）
    table ipv4_lpm {
        key = { hdr.ipv4.dst : lpm; }
        actions = { set_nhop; drop; NoAction; }
        size = 1024;
        default_action = drop;
    }

    // 2. ARP 表（下一跳 IP → 下一跳 MAC）
    table arp {
        key = { meta.nextHop : exact; }
        actions = { rewrite_dst_mac; drop; NoAction; }
        size = 1024;
        default_action = drop;
    }

    // 3. 出端口 → 源 MAC
    table smac {
        key = { std.egress_spec : exact; }
        actions = { rewrite_src_mac; drop; NoAction; }
        size = 64;
        default_action = drop;
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.ipv4.ttl > 1) {
            ipv4_lpm.apply();
            if (std.egress_spec == 511) return;   // drop
            arp.apply();
            smac.apply();
        } else {
            drop();
        }
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std) {
    apply { }
}

/* ===== 出方向校验和重算 ===== */
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

/* ===== Deparser ===== */
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
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
