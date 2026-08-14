"""后端启动入口(支持命令行参数)。

用法:
    uv run cubestack-installer-installer [--admin-password <密码>] [--host <IP>] [--port <端口>] [--reload]
"""
import argparse
import os

DEFAULT_ADMIN_PASSWORD = "admin@123"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="CubeStackInstaller 后端启动器",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--admin-password",
        dest="admin_password",
        metavar="PASSWORD",
        help="管理员初始密码(仅首次创建 admin 账号时生效);不指定时默认 " + DEFAULT_ADMIN_PASSWORD,
    )
    parser.add_argument("--host", default="0.0.0.0", help="监听地址")
    parser.add_argument("--port", type=int, default=8000, help="监听端口")
    parser.add_argument("--reload", action="store_true", help="开发模式热重载")
    args = parser.parse_args()

    if args.admin_password:
        os.environ["ADMIN_INITIAL_PASSWORD"] = args.admin_password

    import uvicorn

    uvicorn.run("app.main:app", host=args.host, port=args.port, reload=args.reload)


if __name__ == "__main__":
    main()
