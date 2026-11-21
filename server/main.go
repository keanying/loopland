// 圈圈 Loopland 后端入口。
//
// 和 `python main.py` 一样直接运行或在 IDE 里调试这个文件（工作目录为 server/，
// 自动读取 ./config.yaml）：
//
//	go run .                    启动 API（默认 :8080）
//	go run . -config x.yaml     用指定的配置文件启动
//	go run . seed [-admin u:p]  往正在运行的 dev 后端写演示数据
//	go run . doctor             检查配置和各第三方服务
//	go run . help               查看说明
//
// IntelliJ IDEA / GoLand：打开仓库根目录，运行配置里选「后端 API」（.run/ 目录），
// 点调试即可下断点。命令行也可以 `go run main.go`。
package main

import (
	"fmt"
	"os"

	"github.com/keanying/loopland/server/internal/cmd/api"
	"github.com/keanying/loopland/server/internal/cmd/doctor"
	"github.com/keanying/loopland/server/internal/cmd/seed"
)

func main() {
	args := os.Args[1:]
	cmd := "api"
	if len(args) > 0 && len(args[0]) > 0 && args[0][0] != '-' {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "api", "serve":
		api.Main(args)
	case "seed":
		seed.Main(args)
	case "doctor":
		doctor.Main(args)
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "未知命令 %q\n\n", cmd)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Print(`圈圈 Loopland 后端

用法（在 server/ 目录）：
  go run .                    启动 API
  go run . -config x.yaml     用指定的配置文件启动 API
  go run . seed [-admin u:p]  往正在运行的 dev 后端写演示数据（-api 指定地址）
  go run . doctor [-sms-to 手机号] [-mail-to 邮箱] [-realname '姓名,身份证号']
                              检查配置和各第三方服务

配置：./config.yaml（本机覆盖写 config.local.yaml 或用环境变量），见 docs/本地启动.md。
`)
}
