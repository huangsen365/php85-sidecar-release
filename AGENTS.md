# 给 AI 助手的说明

这个仓库是一个运维工具：在跑着 CentOS 7 老容器（Apache httpd + Remi php74 的 php-fpm 池）的服务器上，旁边加一个
PHP 8.5 的 php-fpm 容器（sidecar），再把站点一台服务器、一个站点地切到 PHP 8.5，随时可以切回去。

用户让你部署、切换、回滚、升级或排查时，**先完整读 `.claude/skills/php85-sidecar/SKILL.md`，按它的顺序做**。
设计和原理在 `README.md`。

必须遵守的规则（细节在 SKILL.md）：

- 这些操作改的是生产服务器。只读的步骤可以直接做；会改动服务器的步骤，先告诉用户要改什么、影响什么、怎么回滚，
  得到明确同意后再执行。
- 一次只动一台服务器、一个站点。每个脚本结尾是 `RESULT: OK` 才做下一步；失败就停下来报告，不要绕过。
- 不要重启或 reload 老容器里 php74 的 php-fpm，不要重启老容器，不要 `docker compose down` 正在承接流量的 sidecar。
- 不要打印 `.env`、密码、密钥。不要把用户的域名、IP、路径写进这个仓库的文件、提交或 issue。
- 环境不符合 `scripts/preflight.sh` 的要求时，如实告诉用户哪里不符合，不要自己改脚本硬上。

修改这个仓库本身时：`tests/e2e.sh` 必须输出 `RESULT: OK`（在一台没有部署 sidecar 的测试机上跑）。
