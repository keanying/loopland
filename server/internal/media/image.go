package media

import (
	"bytes"
	"encoding/binary"
	"image"
	_ "image/jpeg" // decoders for DecodeConfig
	_ "image/png"

	_ "golang.org/x/image/webp"
)

// Kinds of image accepted for upload, by sniffed type.
var extOf = map[string]string{"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic"}

// Sniff returns the MIME type of an accepted image from its bytes ("" when
// the bytes are not jpeg, png, webp or heic, whatever the file name says).
func Sniff(b []byte) string {
	switch {
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF:
		return "image/jpeg"
	case bytes.HasPrefix(b, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case len(b) >= 12 && string(b[0:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	case len(b) >= 12 && string(b[4:8]) == "ftyp":
		switch string(b[8:12]) {
		case "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1":
			return "image/heic"
		}
	}
	return ""
}

// Dimensions reads the displayed width and height (JPEG EXIF rotation
// applied). ok is false when they cannot be read (heic, broken files).
func Dimensions(b []byte, contentType string) (w, h int, ok bool) {
	if contentType == "image/heic" {
		return 0, 0, false
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(b))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 {
		return 0, 0, false
	}
	w, h = cfg.Width, cfg.Height
	if contentType == "image/jpeg" {
		if o := jpegOrientation(b); o >= 5 && o <= 8 {
			w, h = h, w
		}
	}
	return w, h, true
}

// jpegOrientation returns the EXIF Orientation tag (1 when absent).
func jpegOrientation(b []byte) int {
	i := 2
	for i+4 <= len(b) {
		if b[i] != 0xFF {
			return 1
		}
		marker := b[i+1]
		if marker == 0xD9 || marker == 0xDA { // end of image / start of scan
			return 1
		}
		size := int(binary.BigEndian.Uint16(b[i+2 : i+4]))
		if size < 2 || i+2+size > len(b) {
			return 1
		}
		seg := b[i+4 : i+2+size]
		if marker == 0xE1 && len(seg) > 14 && string(seg[:6]) == "Exif\x00\x00" {
			return tiffOrientation(seg[6:])
		}
		i += 2 + size
	}
	return 1
}

func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 1
	}
	off := int(bo.Uint32(t[4:8]))
	if off < 8 || off+2 > len(t) {
		return 1
	}
	n := int(bo.Uint16(t[off : off+2]))
	for k := 0; k < n; k++ {
		e := off + 2 + 12*k
		if e+12 > len(t) {
			return 1
		}
		if bo.Uint16(t[e:e+2]) == 0x0112 {
			if v := int(bo.Uint16(t[e+8 : e+10])); v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}
	return 1
}
