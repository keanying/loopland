package user

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	cloudauth "github.com/alibabacloud-go/cloudauth-20190307/v4/client"
	openapiutil "github.com/alibabacloud-go/darabonba-openapi/v2/utils"
	"github.com/alibabacloud-go/tea/tea"
)

// AliyunRealname uses 阿里云实人认证 身份证二要素核验 (Id2MetaVerify). Data is
// sent in md5 mode so the birth date and the first character of the name
// never leave the server in plaintext. The local checksum check runs first,
// so obviously wrong input does not cost a paid call.
type AliyunRealname struct {
	cli *cloudauth.Client
}

// NewAliyunRealname builds the verifier.
func NewAliyunRealname(ak, sk string) (*AliyunRealname, error) {
	cli, err := cloudauth.NewClient(&openapiutil.Config{AccessKeyId: tea.String(ak), AccessKeySecret: tea.String(sk),
		Endpoint: tea.String("cloudauth.aliyuncs.com")})
	if err != nil {
		return nil, err
	}
	return &AliyunRealname{cli: cli}, nil
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

// Md5Params builds the md5-mode IdentifyNum and UserName.
func Md5Params(name, id string) (idNum, userName string) {
	id = strings.ToUpper(strings.TrimSpace(id))
	name = strings.TrimSpace(name)
	_, size := utf8.DecodeRuneInString(name)
	return id[:6] + md5hex(id[6:14]) + id[14:], md5hex(name[:size]) + name[size:]
}

// Verify implements Realname.
func (a *AliyunRealname) Verify(ctx context.Context, name, id string) (time.Time, error) {
	birth, err := ChecksumRealname{}.Verify(ctx, name, id)
	if err != nil {
		return time.Time{}, err
	}
	idNum, userName := Md5Params(name, id)
	resp, err := a.cli.Id2MetaVerify(&cloudauth.Id2MetaVerifyRequest{
		ParamType: tea.String("md5"), IdentifyNum: tea.String(idNum), UserName: tea.String(userName)})
	if err != nil {
		return time.Time{}, fmt.Errorf("实名认证服务暂时不可用，请稍后再试")
	}
	if resp.Body == nil || tea.StringValue(resp.Body.Code) != "200" || resp.Body.ResultObject == nil {
		return time.Time{}, fmt.Errorf("实名认证服务暂时不可用，请稍后再试")
	}
	switch tea.StringValue(resp.Body.ResultObject.BizCode) {
	case "1":
		return birth, nil
	case "3":
		return time.Time{}, fmt.Errorf("查无此身份证号")
	default:
		return time.Time{}, fmt.Errorf("姓名与身份证号不一致")
	}
}
