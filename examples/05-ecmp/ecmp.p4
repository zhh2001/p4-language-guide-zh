/*
 * examples/05-ecmp/ecmp.p4
 *
 * ECMP 等价多路径：
 *   一台交换机到目的网段有 N 条等价路径。
 *   对每个流（5-tuple）做 CRC32 哈希，选择其中一条路径，同一流稳定走一条。
 *
 * 实现方式：两张表。
 *   1) ipv4_lpm  —— 命中后 set_ecmp_group(group_id, group_size)
 *   2) ecmp_group_to_nh  —— key=(group_id, hash_index) → 具体的 nh + 出端口
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
    mac_t dst; mac_t src; bit<16> etherType;
}
header ipv4_h {
    bit<4>  version; bit<4>  ihl;
    bit<8>  diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8>  ttl; bit<8>  protocol;
    bit<16> hdrChecksum;
    ipv4_t  src; ipv4_t dst;
}
header l4_ports_h { bit<16> src; bit<16> dst; }

struct headers {
    ethernet_h ethernet;
    ipv4_h     ipv4;
    l4_ports_h l4;
}

struct metadata {
    bit<16> ecmp_group_id;
    bit<16> ecmp_hash;
}

parser MyParser(packet_in p, out headers hdr, inout metadata m, inout standard_metadata_t s) {
    state start { p.extract(hdr.ethernet); transition select(hdr.ethernet.etherType) { TYPE_IPV4: parse_ipv4; default: accept; } }
    state parse_ipv4 {
        p.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP: parse_l4;
            PROTO_UDP: parse_l4;
            default:   accept;
        }
    }
    state parse_l4 { p.extract(hdr.l4); transition accept; }
}

control MyVerifyChecksum(inout headers hdr, inout metadata m) {
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

control MyIngress(inout headers hdr, inout metadata m, inout standard_metadata_t s) {

    action drop() { mark_to_drop(s); }

    action set_ecmp_group(bit<16> group_id, bit<16> group_size) {
        m.ecmp_group_id = group_id;
        // crc32 over 5-tuple, 然后 % group_size
        hash(m.ecmp_hash,
             HashAlgorithm.crc32,
             16w0,
             { hdr.ipv4.src, hdr.ipv4.dst, hdr.ipv4.protocol,
               hdr.l4.src,   hdr.l4.dst },
             group_size);
    }

    action set_nh(mac_t dmac, mac_t smac, port_t port) {
        hdr.ethernet.dst = dmac;
        hdr.ethernet.src = smac;
        s.egress_spec    = port;
        hdr.ipv4.ttl     = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = { hdr.ipv4.dst : lpm; }
        actions = { set_ecmp_group; drop; NoAction; }
        size = 1024;
        default_action = drop;
    }

    table ecmp_group_to_nh {
        key = {
            m.ecmp_group_id : exact;
            m.ecmp_hash     : exact;
        }
        actions = { set_nh; drop; NoAction; }
        size = 1024;
        default_action = drop;
    }

    apply {
        if (hdr.ipv4.isValid() && hdr.ipv4.ttl > 1) {
            ipv4_lpm.apply();
            ecmp_group_to_nh.apply();
        } else { drop(); }
    }
}

control MyEgress(inout headers hdr, inout metadata m, inout standard_metadata_t s) { apply { } }

control MyComputeChecksum(inout headers hdr, inout metadata m) {
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

control MyDeparser(packet_out p, in headers hdr) {
    apply {
        p.emit(hdr.ethernet);
        p.emit(hdr.ipv4);
        p.emit(hdr.l4);
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
