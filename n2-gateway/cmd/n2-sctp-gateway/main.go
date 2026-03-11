package main

import (
	"flag"
	"log"

	"openziti-5gc/n2-gateway/internal/gateway"
)

func main() {
	var cfg gateway.Config

	flag.StringVar(&cfg.Mode, "mode", "", "gateway mode: gnb or core")
	flag.StringVar(&cfg.SCTPListen, "sctp-listen", "127.0.0.1:38412", "local SCTP listen address for gNB mode")
	flag.StringVar(&cfg.UDPRemote, "udp-remote", "amf.ziti:38412", "remote UDP address for gNB mode")
	flag.StringVar(&cfg.UDPListen, "udp-listen", "127.0.0.1:38413", "local UDP listen address for core mode")
	flag.StringVar(&cfg.AMFAddress, "amf-sctp", "127.0.0.18:38412", "AMF SCTP address for core mode")
	flag.Parse()

	if err := gateway.Run(cfg); err != nil {
		log.Fatal(err)
	}
}
