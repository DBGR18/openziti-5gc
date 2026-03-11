//go:build linux

package gateway

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/free5gc/sctp"
)

func TestGatewayPreservesSCTPMetadataOverUDP(t *testing.T) {
	const (
		gnbSCTPAddr  = "127.0.0.1:39012"
		coreUDPAddr  = "127.0.0.1:39013"
		amfSCTPAddr  = "127.0.0.18:39022"
		expectedPPID = 60
		expectedSID  = 3
	)

	listener, err := sctp.ListenSCTP("sctp", mustResolveSCTP(t, amfSCTPAddr))
	if err != nil {
		if errors.Is(err, syscall.EPROTONOSUPPORT) {
			t.Skipf("SCTP is not available on this host: %v", err)
		}
		t.Fatalf("listen SCTP mock AMF: %v", err)
	}
	defer listener.Close()

	amfRead := make(chan *sctp.SndRcvInfo, 1)
	amfErr := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptSCTP(2000)
		if err != nil {
			amfErr <- err
			return
		}
		defer conn.Close()
		if err := conn.SubscribeEvents(sctp.SCTP_EVENT_DATA_IO); err != nil {
			amfErr <- err
			return
		}

		buf := make([]byte, 1024)
		n, info, notification, err := conn.SCTPRead(buf)
		if err != nil {
			amfErr <- err
			return
		}
		if notification != nil {
			amfErr <- fmt.Errorf("unexpected SCTP notification type 0x%x", notification.Type())
			return
		}
		amfRead <- info
		if _, err := conn.SCTPWrite(buf[:n], info); err != nil {
			amfErr <- err
			return
		}
		amfErr <- nil
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	binaryPath := buildGatewayBinary(t)
	gnbCmd, gnbLogs := startGatewayProcess(t, ctx, binaryPath,
		"--mode", "gnb",
		"--sctp-listen", gnbSCTPAddr,
		"--udp-remote", coreUDPAddr,
	)
	defer stopProcess(t, gnbCmd, gnbLogs)

	coreCmd, coreLogs := startGatewayProcess(t, ctx, binaryPath,
		"--mode", "core",
		"--udp-listen", coreUDPAddr,
		"--amf-sctp", amfSCTPAddr,
	)
	defer stopProcess(t, coreCmd, coreLogs)

	client := waitForSCTPClient(t, gnbSCTPAddr, 5*time.Second)
	defer client.Close()
	if err := client.SubscribeEvents(sctp.SCTP_EVENT_DATA_IO); err != nil {
		t.Fatalf("subscribe client events: %v", err)
	}

	payload := []byte("ng-setup-request")
	info := &sctp.SndRcvInfo{Stream: expectedSID, PPID: expectedPPID}
	if _, err := client.SCTPWrite(payload, info); err != nil {
		t.Fatalf("client SCTPWrite: %v", err)
	}

	select {
	case got := <-amfRead:
		if got == nil {
			t.Fatal("mock AMF received nil sndrcv info")
		}
		if got.PPID != expectedPPID || int(got.Stream) != expectedSID {
			t.Fatalf("metadata mismatch at mock AMF: stream=%d ppid=%d", got.Stream, got.PPID)
		}
	case err := <-amfErr:
		if err != nil {
			t.Fatalf("mock AMF error before read: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for mock AMF to receive data")
	}

	buf := make([]byte, 1024)
	n, echoInfo, notification, err := client.SCTPRead(buf)
	if err != nil {
		t.Fatalf("client SCTPRead: %v", err)
	}
	if notification != nil {
		t.Fatalf("unexpected notification at client: 0x%x", notification.Type())
	}
	if !bytes.Equal(buf[:n], payload) {
		t.Fatalf("payload mismatch: got %q want %q", buf[:n], payload)
	}
	if echoInfo == nil || echoInfo.PPID != expectedPPID || int(echoInfo.Stream) != expectedSID {
		t.Fatalf("metadata mismatch at client: %+v", echoInfo)
	}

	if err := <-amfErr; err != nil {
		t.Fatalf("mock AMF error: %v", err)
	}
}

func buildGatewayBinary(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	moduleRoot := filepath.Clean(filepath.Join(wd, "..", ".."))
	binaryPath := filepath.Join(t.TempDir(), "n2-sctp-gateway")
	cmd := exec.Command("go", "build", "-o", binaryPath, "./cmd/n2-sctp-gateway")
	cmd.Dir = moduleRoot
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build gateway binary: %v\n%s", err, output)
	}
	return binaryPath
}

func startGatewayProcess(t *testing.T, ctx context.Context, binaryPath string, args ...string) (*exec.Cmd, *bytes.Buffer) {
	t.Helper()
	cmd := exec.CommandContext(ctx, binaryPath, args...)
	var logs bytes.Buffer
	cmd.Stdout = &logs
	cmd.Stderr = &logs
	if err := cmd.Start(); err != nil {
		t.Fatalf("start gateway %v: %v", args, err)
	}
	return cmd, &logs
}

func stopProcess(t *testing.T, cmd *exec.Cmd, logs *bytes.Buffer) {
	t.Helper()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	err := cmd.Wait()
	if err == nil || errors.Is(err, os.ErrProcessDone) {
		return
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return
	}
	t.Fatalf("gateway process wait failed: %v\nlogs:\n%s", err, logs.String())
}

func waitForSCTPClient(t *testing.T, address string, timeout time.Duration) *sctp.SCTPConn {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		conn, err := sctp.DialSCTP("sctp", nil, mustResolveSCTP(t, address))
		if err == nil {
			return conn
		}
		lastErr = err
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("dial SCTP %s: %v", address, lastErr)
	return nil
}

func mustResolveSCTP(t *testing.T, address string) *sctp.SCTPAddr {
	t.Helper()
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("split host port %q: %v", address, err)
	}
	ipAddr, err := net.ResolveIPAddr("ip", host)
	if err != nil {
		t.Fatalf("resolve %q: %v", host, err)
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil {
		t.Fatalf("lookup port %q: %v", portText, err)
	}
	return &sctp.SCTPAddr{IPAddrs: []net.IPAddr{*ipAddr}, Port: port}
}
