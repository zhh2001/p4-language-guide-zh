/*
 * examples/01-hello/hello.p4
 *
 * 最小可运行的 P4 程序：把每个报文从它进入的端口原路返回。
 * 配合教程 docs/03-第一个P4程序.md 食用。
 *
 * 编译:  p4c-bm2-ss --target bmv2 --arch v1model -o hello.json hello.p4
 * 运行:  参见 run.sh
 */

#include <core.p4>
#include <v1model.p4>

/* ===== 空的 headers / metadata ===== */
struct headers  { }
struct metadata { }

/* ===== Parser ===== */
parser MyParser(packet_in                packet,
                out headers              hdr,
                inout metadata           meta,
                inout standard_metadata_t std_meta) {
    state start {
        transition accept;   // 不解析任何头，直接放行
    }
}

/* ===== Verify Checksum（占位） ===== */
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/* ===== Ingress —— 核心逻辑 ===== */
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t std_meta) {
    apply {
        // "报文反射"：把出端口设成入端口
        std_meta.egress_spec = std_meta.ingress_port;
    }
}

/* ===== Egress（占位） ===== */
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t std_meta) {
    apply { }
}

/* ===== Compute Checksum（占位） ===== */
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/* ===== Deparser（占位） ===== */
control MyDeparser(packet_out packet, in headers hdr) {
    apply { }
}

/* ===== 顶层包实例化 ===== */
V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
