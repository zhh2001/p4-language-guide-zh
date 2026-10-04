/*
 * examples/03-ipv4-router/router.p4
 *
 * 无 VLAN、无 IPv4 选项的静态转发实验：
 *   - 检查解析错误、IPv4 长度和报头校验和
 *   - LPM 匹配目的 IPv4 → 输出端口 + 下一跳 IP
 *   - 改写目的 MAC 为下一跳的 MAC（通过 arp 表查询）
 *   - 改写源 MAC 为交换机出端口的 MAC
 *   - TTL <= 1 时丢弃，正常转发时 TTL 减 1
 *   - 重新计算 IPv4 校验和
 */

#include <core.p4>
#include <v1model.p4>

/* ===== 类型 ===== */
typedef bit<48> mac_t;
typedef bit<32> ipv4_t;
typedef bit<9>  port_t;

const bit<16> TYPE_IPV4 = 0x0800;

error { BadIPv4Version, UnsupportedIPv4Ihl, BadIPv4Length }

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
        verify(hdr.ipv4.version == 4, error.BadIPv4Version);
        verify(hdr.ipv4.ihl == 5, error.UnsupportedIPv4Ihl);
        verify(hdr.ipv4.totalLen >= 20, error.BadIPv4Length);
        // 成功提取两份报头后，普通入站帧至少有 34 字节。
        verify((bit<32>)hdr.ipv4.totalLen <= std.packet_length - 14,
               error.BadIPv4Length);
        transition accept;
    }
}

/* ===== 入方向校验和 ===== */
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid() && hdr.ipv4.version == 4 && hdr.ipv4.ihl == 5,
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
    }

    action rewrite_src_mac(mac_t src) { hdr.ethernet.src = src; }
    action rewrite_dst_mac(mac_t dst) { hdr.ethernet.dst = dst; }

    // 1. 路由表（LPM）
    table ipv4_lpm {
        key = { hdr.ipv4.dst : lpm; }
        actions = { set_nhop; drop; }
        size = 1024;
        const default_action = drop();
    }

    // 2. 静态邻居表（下一跳 IP → 下一跳 MAC），不收发 ARP 报文。
    table arp {
        key = { meta.nextHop : exact; }
        actions = { rewrite_dst_mac; drop; }
        size = 1024;
        const default_action = drop();
    }

    // 3. 出端口 → 源 MAC
    table smac {
        key = { std.egress_spec : exact; }
        actions = { rewrite_src_mac; drop; }
        size = 64;
        const default_action = drop();
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
        if (hdr.ipv4.ttl <= 1) {
            mark_to_drop(std);
            exit;
        }
        // 根据实际执行的动作决定是否继续，不依赖固定的丢弃端口号。
        switch (ipv4_lpm.apply().action_run) {
            set_nhop: { }
            default: { exit; }
        }
        switch (arp.apply().action_run) {
            rewrite_dst_mac: { }
            default: { exit; }
        }
        switch (smac.apply().action_run) {
            rewrite_src_mac: { hdr.ipv4.ttl = hdr.ipv4.ttl - 1; }
            default: { exit; }
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
            hdr.ipv4.isValid() && hdr.ipv4.version == 4 && hdr.ipv4.ihl == 5,
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
