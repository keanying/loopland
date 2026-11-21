package media

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"image/png"
	"testing"
)

func TestSniffAndDimensions(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 40, 30))
	var pb, jb bytes.Buffer
	_ = png.Encode(&pb, img)
	_ = jpeg.Encode(&jb, img, nil)
	cases := []struct {
		data []byte
		ct   string
	}{
		{pb.Bytes(), "image/png"},
		{jb.Bytes(), "image/jpeg"},
		{append([]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), make([]byte, 20)...), "image/webp"},
		{append([]byte("\x00\x00\x00\x18ftypheic"), make([]byte, 20)...), "image/heic"},
		{[]byte("GIF89a......"), ""},
		{[]byte("<svg xmlns='http://www.w3.org/2000/svg'/>"), ""},
	}
	for _, c := range cases {
		if got := Sniff(c.data); got != c.ct {
			t.Errorf("sniff %q: got %q want %q", c.data[:8], got, c.ct)
		}
	}
	if w, h, ok := Dimensions(pb.Bytes(), "image/png"); !ok || w != 40 || h != 30 {
		t.Fatalf("png dims %d×%d", w, h)
	}
	if _, _, ok := Dimensions(cases[3].data, "image/heic"); ok {
		t.Fatal("heic dims should be unknown")
	}
	// EXIF orientation 6 (rotate 90°) swaps the displayed size.
	rot := withOrientation(jb.Bytes(), 6)
	if w, h, ok := Dimensions(rot, "image/jpeg"); !ok || w != 30 || h != 40 {
		t.Fatalf("rotated jpeg dims %d×%d ok=%v", w, h, ok)
	}
	if o := jpegOrientation(jb.Bytes()); o != 1 {
		t.Fatalf("plain jpeg orientation %d", o)
	}
}

// withOrientation inserts an APP1 EXIF segment with one Orientation entry.
func withOrientation(j []byte, o uint16) []byte {
	var tiff bytes.Buffer
	tiff.WriteString("MM\x00\x2a")
	_ = binary.Write(&tiff, binary.BigEndian, uint32(8))
	_ = binary.Write(&tiff, binary.BigEndian, uint16(1))
	_ = binary.Write(&tiff, binary.BigEndian, []uint16{0x0112, 3})
	_ = binary.Write(&tiff, binary.BigEndian, uint32(1))
	_ = binary.Write(&tiff, binary.BigEndian, []uint16{o, 0})
	_ = binary.Write(&tiff, binary.BigEndian, uint32(0))
	seg := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	var out bytes.Buffer
	out.Write(j[:2])
	out.Write([]byte{0xFF, 0xE1})
	_ = binary.Write(&out, binary.BigEndian, uint16(len(seg)+2))
	out.Write(seg)
	out.Write(j[2:])
	return out.Bytes()
}

func TestValidKey(t *testing.T) {
	for _, k := range []string{"post/2026/11/21/ab12.jpg", "chat/x.png"} {
		if !validKey(k) {
			t.Errorf("%s rejected", k)
		}
	}
	for _, k := range []string{"", "../etc/passwd", "post//x.jpg", "post/.hidden", "Post/X.JPG", "post/a b.jpg", "/abs.jpg"} {
		if validKey(k) {
			t.Errorf("%q accepted", k)
		}
	}
}
