/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

#define MAX_HOPS 4
#define BLOOM_FILTER_ENTRIES 4096
#define BLOOM_FILTER_BIT_WIDTH 3

const bit<16> TYPE_SFC = 0x1234;
const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  TYPE_TCP  = 6;

const bit<2> STATUS_INIT = 0;
const bit<2> STATUS_RUNNING = 1;
const bit<2> STATUS_FAILED = 2;
const bit<2> STATUS_DONE = 3;

const bit<2> QOS_TOP = 0;
const bit<2> QOS_HIGH = 1;
const bit<2> QOS_MEDIUM = 2;
const bit<2> QOS_LOW = 3;

const bit<4> APP_TYPE_GENERAL = 0;
const bit<4> APP_TYPE_WEB = 1;

const bit<6> SVC_TYPE_PROXY = 0;
const bit<6> SVC_TYPE_FIRWALL = 1;
const bit<6> SVC_TYPE_QOS = 2;
const bit<6> SVC_TYPE_LOAD_BALANCE = 3;

const bit<15> CONTEXT_PROXY= 1000;
const bit<15> CONTEXT_FIREWALL = 1024;
const bit<15> CONTEXT_QOS = 1336;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header sfc_header_t {
    bit<2> version; 
    bit<4> max_size;
    bit<4> app_type;
    bit<2> qos;
    bit<4> dst_id;
}

header sfc_service_t {
    bit<6> svc_type;
    bit<2> status;
    bit<4> act;
    bit<4> params;
}

header sfc_context_t {
    bit<1>  bos;
    bit<15> content;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header tcp_t{
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<1>  cwr;
    bit<1>  ece;
    bit<1>  urg;
    bit<1>  ack;
    bit<1>  psh;
    bit<1>  rst;
    bit<1>  syn;
    bit<1>  fin;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

struct metadata {
    /* empty */
}

struct headers {
    ethernet_t              ethernet;
    sfc_header_t            sfc_header;
    sfc_service_t           sfc_service;
    sfc_context_t[MAX_HOPS] sfc_context;
    ipv4_t                  ipv4;
    tcp_t                   tcp;
}



/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_SFC: parse_sfc_header;
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_sfc_header {
        packet.extract(hdr.sfc_header);
        transition parse_sfc_service;
    }

    state parse_sfc_service {
        packet.extract(hdr.sfc_service);
        transition parse_sfc_context;
    }

    state parse_sfc_context {
        packet.extract(hdr.sfc_context.next);
        transition select(hdr.sfc_context.last.bos) {
            1: parse_ipv4;
            default: parse_sfc_context;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol){
            TYPE_TCP: tcp;
            default: accept;
        }
    }

    state tcp {
       packet.extract(hdr.tcp);
       transition accept;
    }
}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {   
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    register<bit<BLOOM_FILTER_BIT_WIDTH>>(BLOOM_FILTER_ENTRIES) bloom_filter_1;
    register<bit<BLOOM_FILTER_BIT_WIDTH>>(BLOOM_FILTER_ENTRIES) bloom_filter_2;
    bit<32> reg_pos_one; bit<32> reg_pos_two;
    bit<3> reg_val_one; bit<3> reg_val_two;
    bit<1> direction;

    action drop() {
        mark_to_drop(standard_metadata);
    }
    
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    action compute_hashes(ip4Addr_t ipAddr1, ip4Addr_t ipAddr2, bit<16> port1, bit<16> port2){
       //Get register position
       hash(reg_pos_one, HashAlgorithm.crc16, (bit<32>)0, {ipAddr1,
                                                           ipAddr2,
                                                           port1,
                                                           port2,
                                                           hdr.ipv4.protocol},
                                                           (bit<32>)BLOOM_FILTER_ENTRIES);

       hash(reg_pos_two, HashAlgorithm.crc32, (bit<32>)0, {ipAddr1,
                                                           ipAddr2,
                                                           port1,
                                                           port2,
                                                           hdr.ipv4.protocol},
                                                           (bit<32>)BLOOM_FILTER_ENTRIES);
    }

    action check_sfc_service() {
        // Simply used in check, so no-ops
    }

    action update_sfc_service(bit<6> svc_type, 
                              bit<2> status,
                              bit<4> act,
                              bit<4> params) {
        hdr.sfc_service.svc_type = svc_type;
        hdr.sfc_service.status = status;
        hdr.sfc_service.act = act;
        hdr.sfc_service.params = params;
    }

    action add_sfc_context(bit<15> content) {
        hdr.sfc_context.push_front(1);
        hdr.sfc_context[0].setValid();
        hdr.sfc_context[0].content = content;

        // Set the last context to be 1
        hdr.sfc_context[hdr.sfc_context.size - 1].bos = 1;
    }

    action forward_sfc(egressSpec_t port, bit<6> svc_type) {
        standard_metadata.egress_spec = port;
        update_sfc_service(svc_type, STATUS_RUNNING, 0, 0);
    }

    table sfc_forward_exact {
        key = {
            hdr.sfc_header.app_type: exact;
            hdr.sfc_header.dst_id: exact;
            hdr.sfc_service.act: exact;
        }
        actions = {
            forward_sfc;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }
    
    table sfc_service_exact {
        key = {
            hdr.sfc_header.app_type: exact;
            hdr.sfc_service.svc_type: exact;
        }
        actions = {
            check_sfc_service;
            drop;
        }
        size = 1024;
        default_action = drop();
    }

    action set_direction(bit<1> dir) {
        direction = dir;
    }

    table check_ports {
        key = {
            standard_metadata.ingress_port: exact;
            standard_metadata.egress_spec: exact;
        }
        actions = {
            set_direction;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    apply {
        // Assume all packets are sfc-enabled
        if (hdr.sfc_header.isValid()) {
            // Then check if service match
            if (sfc_service_exact.apply().hit) {
                // Finally check how to forward
                if (sfc_forward_exact.apply().hit) {
                    // If need to forward, maybe add some additional context
                    add_sfc_context(CONTEXT_FIREWALL);

                    if (hdr.tcp.isValid()) {
                        direction = 0; // default
                        if (check_ports.apply().hit) {
                            // test and set the bloom filter
                            if (direction == 0) {
                                compute_hashes(hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.tcp.srcPort, hdr.tcp.dstPort);
                            }
                            else {
                                compute_hashes(hdr.ipv4.dstAddr, hdr.ipv4.srcAddr, hdr.tcp.dstPort, hdr.tcp.srcPort);
                            }
                            // Packet comes from internal network
                            if (direction == 0){
                                // If there is a syn we update the bloom filter and add the entry
                                if (hdr.tcp.syn == 1){
                                    log_msg("Add an entry to the firewall, hdr.ipv4.srcAddr={}, hdr.ipv4.dstAddr={}, hdr.tcp.srcPort={}, hdr.tcp.dstPort={}", {hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.tcp.srcPort, hdr.tcp.dstPort});
                                    bloom_filter_1.write(reg_pos_one, 1);
                                    bloom_filter_2.write(reg_pos_two, 1);
                                }
                            }
                            // Packet comes from outside
                            else if (direction == 1){
                                // Read bloom filter cells to check if there are 1's
                                bloom_filter_1.read(reg_val_one, reg_pos_one);
                                bloom_filter_2.read(reg_val_two, reg_pos_two);

                                // only allow flow to pass if both entries are set
                                if (reg_val_one == 0 || reg_val_two == 0){
                                    drop();
                                }
                            }

                            // The FIN packet
                            if (hdr.tcp.fin == 1){
                                bloom_filter_1.read(reg_val_one, reg_pos_one);
                                bloom_filter_2.read(reg_val_two, reg_pos_two);
                                
                                if (direction == 0) {
                                    // set the bloom filter to FIN WAIT state.
                                    bloom_filter_1.write(reg_pos_one, reg_val_one | (bit<3>)2);
                                    bloom_filter_2.write(reg_pos_two, reg_val_two | (bit<3>)2);
                                } else {
                                    // set the bloom filter to FIN WAIT state.
                                    bloom_filter_1.write(reg_pos_one, reg_val_one | (bit<3>)4);
                                    bloom_filter_2.write(reg_pos_two, reg_val_two | (bit<3>)4);
                                }

                                bloom_filter_1.read(reg_val_one, reg_pos_one);
                                bloom_filter_2.read(reg_val_two, reg_pos_two);
                                log_msg("after modify, pos1 = {}, pos2 = {}", {reg_val_one, reg_val_two});
                                
                                if (reg_val_one == 7 && reg_val_two == 7) {
                                    // delete the entry.
                                    log_msg("Remove an entry from the firewall, hdr.ipv4.srcAddr={}, hdr.ipv4.dstAddr={}, hdr.tcp.srcPort={}, hdr.tcp.dstPort={}", {hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.tcp.srcPort, hdr.tcp.dstPort});
                                    bloom_filter_1.write(reg_pos_one, 0);
                                    bloom_filter_2.write(reg_pos_two, 0);
                                }
                            }
                        }
                    }
                }
            } 
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {  }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
	update_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	      hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.sfc_header);
        packet.emit(hdr.sfc_service);
        packet.emit(hdr.sfc_context);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
