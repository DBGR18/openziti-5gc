package gateway

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/free5gc/sctp"
)

const (
	acceptNoTimeout = -1
	maxPayloadSize  = 262144
	dataIOEvents    = sctp.SCTP_EVENT_DATA_IO | sctp.SCTP_EVENT_SHUTDOWN | sctp.SCTP_EVENT_ASSOCIATION
)

type Config struct {
	Mode       string
	SCTPListen string
	UDPRemote  string
	UDPListen  string
	AMFAddress string
}

type gnbSession struct {
	id        uint64
	conn      *sctp.SCTPConn
	closeOnce sync.Once
}

type coreSession struct {
	id        uint64
	peer      *net.UDPAddr
	conn      *sctp.SCTPConn
	closeOnce sync.Once
}

type gnbGateway struct {
	listener   *sctp.SCTPListener
	udpConn    *net.UDPConn
	udpWriteMu sync.Mutex
	sessions   sync.Map
	nextID     atomic.Uint64
}

type coreGateway struct {
	udpConn    *net.UDPConn
	udpWriteMu sync.Mutex
	sessions   sync.Map
	amfAddr    *sctp.SCTPAddr
}

func Run(cfg Config) error {
	switch cfg.Mode {
	case "gnb":
		return runGNB(cfg)
	case "core":
		return runCore(cfg)
	default:
		return fmt.Errorf("unsupported mode %q", cfg.Mode)
	}
}

func runGNB(cfg Config) error {
	listenAddr, err := resolveSCTPAddr(cfg.SCTPListen)
	if err != nil {
		return fmt.Errorf("resolve gNB listen SCTP address: %w", err)
	}
	listener, err := sctp.ListenSCTP("sctp", listenAddr)
	if err != nil {
		return fmt.Errorf("listen SCTP: %w", err)
	}

	udpRemote, err := net.ResolveUDPAddr("udp", cfg.UDPRemote)
	if err != nil {
		return fmt.Errorf("resolve UDP remote %q: %w", cfg.UDPRemote, err)
	}
	udpConn, err := net.DialUDP("udp", nil, udpRemote)
	if err != nil {
		return fmt.Errorf("dial UDP remote %q: %w", cfg.UDPRemote, err)
	}

	gateway := &gnbGateway{listener: listener, udpConn: udpConn}
	log.Printf("[n2gw][gnb] listening for SCTP on %s and forwarding to UDP %s", cfg.SCTPListen, cfg.UDPRemote)

	go gateway.readUDP()

	for {
		conn, err := listener.AcceptSCTP(acceptNoTimeout)
		if err != nil {
			if errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.EAGAIN) {
				continue
			}
			return fmt.Errorf("accept SCTP: %w", err)
		}

		if err := conn.SubscribeEvents(dataIOEvents); err != nil {
			log.Printf("[n2gw][gnb] subscribe events failed: %v", err)
			_ = conn.Close()
			continue
		}
		if err := conn.SetReadBuffer(maxPayloadSize); err != nil {
			log.Printf("[n2gw][gnb] set read buffer failed: %v", err)
		}

		session := &gnbSession{id: gateway.nextID.Add(1), conn: conn}
		gateway.sessions.Store(session.id, session)
		log.Printf("[n2gw][gnb] accepted SCTP session %d from %s", session.id, conn.RemoteAddr())
		go gateway.relaySCTPToUDP(session)
	}
}

func runCore(cfg Config) error {
	listenAddr, err := net.ResolveUDPAddr("udp", cfg.UDPListen)
	if err != nil {
		return fmt.Errorf("resolve UDP listen %q: %w", cfg.UDPListen, err)
	}
	udpConn, err := net.ListenUDP("udp", listenAddr)
	if err != nil {
		return fmt.Errorf("listen UDP: %w", err)
	}

	amfAddr, err := resolveSCTPAddr(cfg.AMFAddress)
	if err != nil {
		return fmt.Errorf("resolve AMF SCTP address: %w", err)
	}

	gateway := &coreGateway{udpConn: udpConn, amfAddr: amfAddr}
	log.Printf("[n2gw][core] listening for UDP on %s and forwarding to SCTP %s", cfg.UDPListen, cfg.AMFAddress)

	buf := make([]byte, maxPayloadSize+frameHeaderSz)
	for {
		n, peer, err := udpConn.ReadFromUDP(buf)
		if err != nil {
			return fmt.Errorf("read UDP: %w", err)
		}

		frame, err := UnmarshalFrame(buf[:n])
		if err != nil {
			log.Printf("[n2gw][core] discard invalid frame from %s: %v", peer, err)
			continue
		}

		switch frame.Type {
		case FrameTypeData:
			session, err := gateway.getOrCreateSession(frame.SessionID, peer)
			if err != nil {
				log.Printf("[n2gw][core] create SCTP session %d failed: %v", frame.SessionID, err)
				continue
			}
			if err := writeSCTP(session.conn, frame); err != nil {
				log.Printf("[n2gw][core] write to AMF for session %d failed: %v", frame.SessionID, err)
				gateway.closeSession(session, true)
			}
		case FrameTypeClose:
			if value, ok := gateway.sessions.Load(frame.SessionID); ok {
				gateway.closeSession(value.(*coreSession), false)
			}
		case FrameTypePing:
			if err := gateway.sendFrame(peer, Frame{Type: FrameTypePong, SessionID: frame.SessionID}); err != nil {
				log.Printf("[n2gw][core] send pong failed: %v", err)
			}
		case FrameTypePong:
			log.Printf("[n2gw][core] received pong for session %d", frame.SessionID)
		}
	}
}

func (g *gnbGateway) relaySCTPToUDP(session *gnbSession) {
	defer g.closeSession(session, true)

	buf := make([]byte, maxPayloadSize)
	for {
		n, info, notification, err := session.conn.SCTPRead(buf)
		if err != nil {
			if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
				continue
			}
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("[n2gw][gnb] session %d closed by local SCTP peer", session.id)
				return
			}
			log.Printf("[n2gw][gnb] session %d SCTP read failed: %v", session.id, err)
			return
		}
		if notification != nil {
			log.Printf("[n2gw][gnb] session %d received SCTP notification type 0x%x", session.id, notification.Type())
			continue
		}

		frame := frameFromSCTP(FrameTypeData, session.id, info, buf[:n])
		if err := g.sendFrame(frame); err != nil {
			log.Printf("[n2gw][gnb] session %d UDP send failed: %v", session.id, err)
			return
		}
	}
}

func (g *gnbGateway) readUDP() {
	buf := make([]byte, maxPayloadSize+frameHeaderSz)
	for {
		n, err := g.udpConn.Read(buf)
		if err != nil {
			log.Printf("[n2gw][gnb] UDP read failed: %v", err)
			return
		}

		frame, err := UnmarshalFrame(buf[:n])
		if err != nil {
			log.Printf("[n2gw][gnb] discard invalid frame: %v", err)
			continue
		}

		value, ok := g.sessions.Load(frame.SessionID)
		if !ok {
			log.Printf("[n2gw][gnb] missing SCTP session %d for inbound frame type %d", frame.SessionID, frame.Type)
			continue
		}
		session := value.(*gnbSession)

		switch frame.Type {
		case FrameTypeData:
			if err := writeSCTP(session.conn, frame); err != nil {
				log.Printf("[n2gw][gnb] write back to SCTP session %d failed: %v", frame.SessionID, err)
				g.closeSession(session, true)
			}
		case FrameTypeClose:
			g.closeSession(session, false)
		case FrameTypePong:
			log.Printf("[n2gw][gnb] received pong for session %d", frame.SessionID)
		}
	}
}

func (g *gnbGateway) sendFrame(frame Frame) error {
	data, err := frame.MarshalBinary()
	if err != nil {
		return err
	}
	g.udpWriteMu.Lock()
	defer g.udpWriteMu.Unlock()
	_, err = g.udpConn.Write(data)
	return err
}

func (g *gnbGateway) closeSession(session *gnbSession, sendClose bool) {
	session.closeOnce.Do(func() {
		g.sessions.Delete(session.id)
		if sendClose {
			if err := g.sendFrame(Frame{Type: FrameTypeClose, SessionID: session.id}); err != nil {
				log.Printf("[n2gw][gnb] send close for session %d failed: %v", session.id, err)
			}
		}
		if err := session.conn.Close(); err != nil && !errors.Is(err, syscall.EBADF) {
			log.Printf("[n2gw][gnb] close SCTP session %d failed: %v", session.id, err)
		}
		log.Printf("[n2gw][gnb] session %d closed", session.id)
	})
}

func (g *coreGateway) getOrCreateSession(sessionID uint64, peer *net.UDPAddr) (*coreSession, error) {
	if value, ok := g.sessions.Load(sessionID); ok {
		session := value.(*coreSession)
		session.peer = peer
		return session, nil
	}

	conn, err := sctp.DialSCTP("sctp", nil, g.amfAddr)
	if err != nil {
		return nil, err
	}
	if err := conn.SubscribeEvents(dataIOEvents); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := conn.SetReadBuffer(maxPayloadSize); err != nil {
		log.Printf("[n2gw][core] set AMF read buffer failed for session %d: %v", sessionID, err)
	}

	session := &coreSession{id: sessionID, peer: peer, conn: conn}
	actual, loaded := g.sessions.LoadOrStore(sessionID, session)
	if loaded {
		_ = conn.Close()
		stored := actual.(*coreSession)
		stored.peer = peer
		return stored, nil
	}

	log.Printf("[n2gw][core] established SCTP session %d to AMF from peer %s", sessionID, peer)
	go g.relayAMFToUDP(session)
	return session, nil
}

func (g *coreGateway) relayAMFToUDP(session *coreSession) {
	defer g.closeSession(session, true)

	buf := make([]byte, maxPayloadSize)
	for {
		n, info, notification, err := session.conn.SCTPRead(buf)
		if err != nil {
			if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
				continue
			}
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				log.Printf("[n2gw][core] AMF closed SCTP session %d", session.id)
				return
			}
			log.Printf("[n2gw][core] session %d AMF read failed: %v", session.id, err)
			return
		}
		if notification != nil {
			log.Printf("[n2gw][core] session %d received SCTP notification type 0x%x", session.id, notification.Type())
			continue
		}

		frame := frameFromSCTP(FrameTypeData, session.id, info, buf[:n])
		if err := g.sendFrame(session.peer, frame); err != nil {
			log.Printf("[n2gw][core] UDP send failed for session %d: %v", session.id, err)
			return
		}
	}
}

func (g *coreGateway) sendFrame(peer *net.UDPAddr, frame Frame) error {
	data, err := frame.MarshalBinary()
	if err != nil {
		return err
	}
	g.udpWriteMu.Lock()
	defer g.udpWriteMu.Unlock()
	_, err = g.udpConn.WriteToUDP(data, peer)
	return err
}

func (g *coreGateway) closeSession(session *coreSession, sendClose bool) {
	session.closeOnce.Do(func() {
		g.sessions.Delete(session.id)
		if sendClose && session.peer != nil {
			if err := g.sendFrame(session.peer, Frame{Type: FrameTypeClose, SessionID: session.id}); err != nil {
				log.Printf("[n2gw][core] send close for session %d failed: %v", session.id, err)
			}
		}
		if err := session.conn.Close(); err != nil && !errors.Is(err, syscall.EBADF) {
			log.Printf("[n2gw][core] close SCTP session %d failed: %v", session.id, err)
		}
		log.Printf("[n2gw][core] session %d closed", session.id)
	})
}

func writeSCTP(conn *sctp.SCTPConn, frame Frame) error {
	info := &sctp.SndRcvInfo{
		Stream:  frame.Stream,
		Flags:   frame.Flags,
		PPID:    frame.PPID,
		Context: frame.Context,
		TTL:     frame.TTL,
	}
	_, err := conn.SCTPWrite(frame.Payload, info)
	return err
}

func frameFromSCTP(frameType uint8, sessionID uint64, info *sctp.SndRcvInfo, payload []byte) Frame {
	frame := Frame{
		Type:      frameType,
		SessionID: sessionID,
		Payload:   append([]byte(nil), payload...),
	}
	if info != nil {
		frame.Stream = info.Stream
		frame.Flags = info.Flags
		frame.PPID = info.PPID
		frame.Context = info.Context
		frame.TTL = info.TTL
	}
	return frame
}

func resolveSCTPAddr(address string) (*sctp.SCTPAddr, error) {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return nil, err
	}
	ipAddr, err := net.ResolveIPAddr("ip", host)
	if err != nil {
		return nil, err
	}
	return &sctp.SCTPAddr{IPAddrs: []net.IPAddr{*ipAddr}, Port: port}, nil
}
