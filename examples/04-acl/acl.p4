/*
 * IPv4 五元组 ACL + 静态 L2 转发。
 * 仅处理无 VLAN、无 IPv4 选项、未分片的报文。
 * ACL 决定是否继续查 L2 表，不递减 TTL，也不改写 MAC 或 IP 报头。
 */
#include <core.p4>
#include <v1model.p4>

typedef bit<48> mac_t;
typedef bit<9> port_t;
const bit<16> TYPE_IPV4 = 0x0800;
const bit<8> PROTO_TCP = 6;
const bit<8> PROTO_UDP = 17;

error {
    BadIPv4Version, UnsupportedIPv4Ihl, BadIPv4Length,
    UnsupportedFragment, BadTcpLength, BadUdpLength
}

header ethernet_h {
    mac_t dst;
    mac_t src;
    bit<16> etherType;
}
header ipv4_h {
    bit<4> version;
    bit<4> ihl;
    bit<8> diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3> flags;
    bit<13> fragOffset;
    bit<8> ttl;
    bit<8> protocol;
    bit<16> hdrChecksum;
    bit<32> src;
    bit<32> dst;
}
header tcp_h {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4> dataOffset;
    bit<4> reserved;
    bit<8> flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}
header udp_h {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length;
    bit<16> checksum;
}
struct headers {
    ethernet_h ethernet;
    ipv4_h ipv4;
    tcp_h tcp;
    udp_h udp;
}
struct metadata {
    bit<16> srcPort;
    bit<16> dstPort;
}

parser MyParser(packet_in packet, out headers hdr,
                inout metadata meta, inout standard_metadata_t std) {
    state start {
        // 非 TCP/UDP 报文使用确定的端口键，不读取无效报头的字段。
        meta.srcPort = 0;
        meta.dstPort = 0;
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        verify(hdr.ipv4.version == 4, error.BadIPv4Version);
        verify(hdr.ipv4.ihl == 5, error.UnsupportedIPv4Ihl);
        verify(hdr.ipv4.totalLen >= 20, error.BadIPv4Length);
        verify((bit<32>)hdr.ipv4.totalLen <= std.packet_length - 14,
               error.BadIPv4Length);
        // 不把后续分片的数据当作端口，也不单独放行首片。
        verify(hdr.ipv4.fragOffset == 0 && hdr.ipv4.flags[0:0] == 0,
               error.UnsupportedFragment);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP: parse_tcp;
            PROTO_UDP: parse_udp;
            default: accept;
        }
    }
    state parse_tcp {
        verify(hdr.ipv4.totalLen >= 40, error.BadTcpLength);
        packet.extract(hdr.tcp);
        verify(hdr.tcp.dataOffset >= 5, error.BadTcpLength);
        verify((bit<16>)hdr.tcp.dataOffset * 4 <= hdr.ipv4.totalLen - 20,
               error.BadTcpLength);
        meta.srcPort = hdr.tcp.srcPort;
        meta.dstPort = hdr.tcp.dstPort;
        // TCP 选项保留在未解析负载中，Deparser 不改变它们的位置。
        transition accept;
    }
    state parse_udp {
        verify(hdr.ipv4.totalLen >= 28, error.BadUdpLength);
        packet.extract(hdr.udp);
        verify(hdr.udp.length >= 8 && hdr.udp.length <= hdr.ipv4.totalLen - 20,
               error.BadUdpLength);
        meta.srcPort = hdr.udp.srcPort;
        meta.dstPort = hdr.udp.dstPort;
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid() && hdr.ipv4.version == 4 && hdr.ipv4.ihl == 5,
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}

control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t std) {
    direct_counter(CounterType.packets_and_bytes) acl_ctr;
    counter(1, CounterType.packets_and_bytes) acl_miss;
    bool permitted;

    action permit() { permitted = true; }
    action deny() { permitted = false; }
    action forward(port_t port) { std.egress_spec = port; }
    action drop() { mark_to_drop(std); }

    table l2 {
        key = { hdr.ethernet.dst: exact; }
        actions = { forward; drop; }
        size = 1024;
        const default_action = drop();
    }
    table acl {
        key = {
            hdr.ipv4.src: ternary;
            hdr.ipv4.dst: ternary;
            hdr.ipv4.protocol: ternary;
            meta.srcPort: ternary;
            meta.dstPort: ternary;
        }
        actions = { permit; deny; }
        counters = acl_ctr;
        size = 1024;
        const default_action = permit();
    }
    apply {
        if (std.parser_error != error.NoError || std.checksum_error == 1) {
            mark_to_drop(std);
            exit;
        }
        if (!hdr.ipv4.isValid()) {
            mark_to_drop(std);
            exit;
        }
        permitted = false;
        if (!acl.apply().hit) {
            acl_miss.count(0);
        }
        if (!permitted) {
            mark_to_drop(std);
            exit;
        }
        l2.apply();
    }
}

control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t std) {
    apply { }
}
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    // 只做二层转发，所有 IPv4 和传输层字段均保持原值。
    apply { }
}
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        packet.emit(hdr.udp);
    }
}
V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
