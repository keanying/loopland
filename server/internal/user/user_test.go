package user

import (
	"context"
	"testing"
	"time"
)

func TestChecksumAndAdult(t *testing.T) {
	b, err := ChecksumRealname{}.Verify(context.Background(), "张三", "110105199003071239")
	if err != nil || b.Format("20060102") != "19900307" {
		t.Fatalf("%v %v", b, err)
	}
	if _, err := (ChecksumRealname{}).Verify(context.Background(), "张三", "110105199003071230"); err == nil {
		t.Fatal("bad checksum accepted")
	}
	day := time.Date(2026, 11, 21, 0, 0, 0, 0, time.UTC)
	if !IsAdult(time.Date(2008, 11, 21, 0, 0, 0, 0, time.UTC), day) || IsAdult(time.Date(2008, 11, 22, 0, 0, 0, 0, time.UTC), day) {
		t.Fatal("18th birthday boundary")
	}
}

func TestMd5Params(t *testing.T) {
	id, name := Md5Params("张三丰", "110105199003071239")
	if id != "110105"+md5hex("19900307")+"1239" || len(id) != 6+32+4 {
		t.Fatalf("id %s", id)
	}
	if name != md5hex("张")+"三丰" {
		t.Fatalf("name %s", name)
	}
}
