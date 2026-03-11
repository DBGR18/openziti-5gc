package gateway

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	frameMagic    = "N2GW"
	frameVersion  = 1
	frameHeaderSz = 32

	FrameTypeData  uint8 = 1
	FrameTypeClose uint8 = 2
	FrameTypePing  uint8 = 3
	FrameTypePong  uint8 = 4
)

var (
	ErrShortFrame    = errors.New("frame too short")
	ErrInvalidMagic  = errors.New("invalid frame magic")
	ErrBadVersion    = errors.New("unsupported frame version")
	ErrBadLength     = errors.New("invalid frame payload length")
	ErrUnknownType   = errors.New("unknown frame type")
	allowedFrameType = map[uint8]struct{}{
		FrameTypeData:  {},
		FrameTypeClose: {},
		FrameTypePing:  {},
		FrameTypePong:  {},
	}
)

type Frame struct {
	Type      uint8
	SessionID uint64
	Stream    uint16
	Flags     uint16
	PPID      uint32
	Context   uint32
	TTL       uint32
	Payload   []byte
}

func (f Frame) MarshalBinary() ([]byte, error) {
	if _, ok := allowedFrameType[f.Type]; !ok {
		return nil, fmt.Errorf("%w: %d", ErrUnknownType, f.Type)
	}

	payloadLen := len(f.Payload)
	out := make([]byte, frameHeaderSz+payloadLen)
	copy(out[:4], []byte(frameMagic))
	out[4] = frameVersion
	out[5] = f.Type
	binary.BigEndian.PutUint16(out[6:8], f.Stream)
	binary.BigEndian.PutUint64(out[8:16], f.SessionID)
	binary.BigEndian.PutUint16(out[16:18], f.Flags)
	binary.BigEndian.PutUint16(out[18:20], 0)
	binary.BigEndian.PutUint32(out[20:24], f.PPID)
	binary.BigEndian.PutUint32(out[24:28], f.Context)
	binary.BigEndian.PutUint32(out[28:32], f.TTL)
	copy(out[frameHeaderSz:], f.Payload)
	return out, nil
}

func UnmarshalFrame(data []byte) (Frame, error) {
	if len(data) < frameHeaderSz {
		return Frame{}, ErrShortFrame
	}
	if string(data[:4]) != frameMagic {
		return Frame{}, ErrInvalidMagic
	}
	if data[4] != frameVersion {
		return Frame{}, fmt.Errorf("%w: %d", ErrBadVersion, data[4])
	}
	if _, ok := allowedFrameType[data[5]]; !ok {
		return Frame{}, fmt.Errorf("%w: %d", ErrUnknownType, data[5])
	}

	payloadLen := len(data) - frameHeaderSz
	if payloadLen < 0 {
		return Frame{}, ErrBadLength
	}

	frame := Frame{
		Type:      data[5],
		Stream:    binary.BigEndian.Uint16(data[6:8]),
		SessionID: binary.BigEndian.Uint64(data[8:16]),
		Flags:     binary.BigEndian.Uint16(data[16:18]),
		PPID:      binary.BigEndian.Uint32(data[20:24]),
		Context:   binary.BigEndian.Uint32(data[24:28]),
		TTL:       binary.BigEndian.Uint32(data[28:32]),
	}
	if payloadLen > 0 {
		frame.Payload = append([]byte(nil), data[frameHeaderSz:]...)
	}
	return frame, nil
}
