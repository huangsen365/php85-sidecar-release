---
name: php85-sidecar
description: 在跑着 CentOS 7 老容器（Apache httpd + Remi php74 的 php-fpm 池）的服务器旁边部署 PHP 8.5 的 php-fpm sidecar 容器，并把站点一台服务器、一个站点地切到 PHP 8.5：只读预检、部署、lint 对比、建池、vhost 测试、切换、验证、一步回滚。用户说 升级 PHP / 上 PHP 8 / PHP 8.5 / CentOS 7 老容器升不了 PHP / 把某个站点切到 8.5 / 切回 php74 / 回滚 / 升级 sidecar 镜像 / 在 8.5 上跑 composer / 先演练一遍 时使用。Deploy a PHP 8.5 php-fpm sidecar next to a CentOS 7 container that runs Remi php74 pools, and switch sites to it one server and one site at a time, with rollback.
---

# php85-sidecar

你在帮用户操作服务器。目标是让站点改用 PHP 8.5，同时线上不出事、随时退得回去。原理和设计在仓库的
`README.md`，开始前读一遍「适用环境」「设计」「与 php74 的差异」。

## 规则

1. **先只读，后改动。** 预检、lint、状态查询可以直接做。下面标了「改动」的步骤，先告诉用户：要改什么、影响哪些
   站点和服务器、怎么撤销（每一步的撤销命令都写在下面），得到明确同意后再执行。一次同意只管一步。
2. **一次一台服务器、一个站点。** 先切已经从负载均衡摘掉流量的那一台，验证通过再放流量，然后才是下一台。
3. **看结尾。** 每个脚本最后一行是 `RESULT: OK`、`RESULT: WARN` 或 `RESULT: FAILED`。`FAILED` 就停下，把原因原样
   告诉用户，不要改脚本、不要跳过检查、不要手工硬做。`WARN` 要逐条向用户说明。
4. **不要碰的东西：** 老容器里 php74 的 php-fpm（重载它会打断所有站点正在处理的请求）、老容器本身、别的站点的
   vhost。httpd 只做平滑重载，由脚本在 `httpd -t` 通过之后做。
5. **保密。** 不打印 `.env`、数据库密码、密钥。用户的域名、IP、路径只用于当前操作，不写进本仓库的文件、提交、
   issue。
6. **共用存储。** 多台服务器挂同一个 NAS 时，池文件和 vhost 改一次、所有服务器都看得到。所以 vhost 换上之前，
   每台都要先测试。

**演练环境例外：** 在 `tests/playground.sh` 起的演练环境里（老容器叫 `php85-playground-old`），没有真实站点，规则 1
的逐步同意可以省掉：开始前向用户确认一次「这是演练环境，我连续做完」即可。其余规则照旧，尤其是规则 3。

## 开始之前问清楚

- 在哪台服务器上做。你是直接在服务器上，还是通过 SSH。需要 root 或能用 docker 的账号。
- 有几台服务器、是否共用存储、流量怎么摘（负载均衡的权重，或者 hosts）。
- 要切哪个站点。站点名取它 php74 池的名字：池是 `[www.example.com-php74]`，站点名就是 `www.example.com`。
- 站点的代码目录（`/var/www` 下的哪个目录）。

把本仓库放在服务器的 `/root/php85-sidecar`，以下命令都在这个目录里执行。通过 SSH 操作时，每条命令都要在服务器上
执行，不是在你本机。

用户想先演练、或者你对环境没有把握时，建议先在一台测试机上演练，见本文最后一节。

## 流程

### 1. 预检（只读）

```bash
scripts/preflight.sh
```

- `FAILED`：这台服务器不在支持范围内。把 `FAIL` 行告诉用户，到此为止。
- `WARN`：逐条解释。常见的有：session 目录不在卷上（切换时已登录用户会掉线）、php74 的池文件在容器里（脚本会
  通过 docker exec 读）、vhost 在容器里（`vhost-*.sh` 用不了，只能按 README 手工做，先和用户确认）。
- 记下它列出的可迁站点（`74NN:<站点>`）和不能迁的池。用户要切的站点不在可迁列表里，就不能用这套工具切。
- 有多个老容器时把名字作为参数：`scripts/preflight.sh <容器名>`。

### 2. 镜像

```bash
docker pull ghcr.io/huangsen365/php85-sidecar:<标签>
# 拉不到 ghcr.io 时：让用户从 Release 页面下载离线包和 .sha256，传到服务器上
sha256sum -c php85-sidecar_<标签>.tar.gz.sha256 && gunzip -c php85-sidecar_<标签>.tar.gz | docker load
```

标签用 Release 页面上最新的。校验不通过不要加载。离线包加载出来有两个名字（带 `ghcr.io/…` 前缀的和不带的），
是同一个镜像，后面统一用带前缀的那个。

### 3. 部署 sidecar（改动：这台多一个容器，不影响任何站点）

```bash
scripts/deploy.sh ghcr.io/huangsen365/php85-sidecar:<标签>
```

- 它会再跑一遍预检、写 `.env`、建目录、启动容器、跑冒烟测试、检查老容器连得到 sidecar。必须以 `RESULT: OK` 结束。
- 已经有 `.env` 时它原样使用，不会覆盖。提示「using the existing」时，先确认这个 `.env` 是这台机器的
  （`OLD_CONTAINER` 是这台的老容器），不是从别处拷来的或演练留下的。
- 撤销：`docker compose down`（前提是这台还没有站点切到 8.5）。
- 多台服务器：每台都要部署，才能在那台上切站点。

### 4. 切一个站点

| 步骤 | 命令 | 在哪做 | 性质 | 撤销 |
|---|---|---|---|---|
| a | `scripts/lint-compare.sh <代码目录>` | 一台 | 只读 | 不需要 |
| b | `scripts/pool-add.sh <站点>` | 每台有 sidecar 的 | 改动：新增池文件、sidecar 平滑重载；站点仍在 php74 | `scripts/pool-remove.sh <站点>` |
| c | `scripts/vhost-stage.sh <站点>` | 每台 | 不动线上：只在本目录写 `staging/`、`backup/` | 不需要 |
| d | `scripts/vhost-test.sh <站点>` | 每台 | 不动线上：只在老容器的 `/tmp` 放临时副本，结束时删掉 | 不需要 |
| e | `scripts/vhost-apply.sh <站点>` | 共用存储做一次，否则每台 | 改动：vhost 多一行 include，不重载 httpd，行为不变 | `scripts/vhost-restore.sh <站点>` |
| f | `scripts/site-switch.sh on <站点>` | 要切的那一台 | 改动：这个站点在这台上改走 8.5 | `scripts/site-switch.sh off <站点>` |
| g | `scripts/site-status.sh <站点>` | 切了的那台 | 只读 | 不需要 |

c 和 d 不需要用户同意，可以连着做。

要点：

- **a.** 把 `NEW-8.5` 的文件列给用户：这些在 8.5 下编译不过，访问到就是 500。数量不为 0 时，建议先让开发修，
  是否继续由用户决定。lint 只查得出语法问题，告诉用户运行时问题要靠测试。目录里有不该扫的路径时用
  `EXCLUDE='./runtime/* ./vendor/*'`。
- **b.** 报「the site may call …, which the sidecar disables」时，这个站点不能原样迁（它需要的函数在 8.5 这边
  被统一禁用），停下来告诉用户。stderr 里的 `note: callable on 8.5, disabled on 7.4` 也要转告：这些函数在 8.5
  上会变成可用。
- **c.** 把打印出来的差异给用户看：应该只多一行 `IncludeOptional conf.d/php85-<站点>*.inc`，在 PHP 那一行之前、
  `gitpull.php` 那一行之后。
- **d.** 四条都是 `OK` 才能做 e。共用存储时每台服务器都要通过。
- **e.** 做完后没有任何站点改变。脚本在 `httpd -t` 失败时会自动换回原 vhost。
- **f.** 做之前确认：这台已经摘掉流量，或者用户明确同意直接切。做完立刻做 g，并让用户测试业务。
- **g.** 验证三件事：
  1. 页面正常：`curl -sk -o /dev/null -w '%{http_code}\n' --resolve <站点>:443:<这台的 IP> https://<站点>/`，再让用户测业务。
  2. 请求确实到了 8.5：先记下 `accepted conn`，发几个业务请求，再查一次。脚本自己每查一次也会让这个数加 1，
     所以要涨得比你查的次数多才算数。
  3. 错误日志没有新的报错。

验证通过、用户确认后，把这台的流量放回去，再到下一台从 b 开始（共用存储时 e 不用重复，脚本会说
「already has the include line」）。

### 5. 回滚（改动：这个站点在这台上回到 php74）

```bash
scripts/site-switch.sh off <站点>
```

出现用户不能接受的问题时，先回滚、再排查。这一条就够了：池文件和 vhost 里那一行留着不起作用。

用户要求连准备工作也撤掉时，按这个顺序，每条都是改动：所有服务器上先 `site-switch.sh off`，再
`scripts/vhost-restore.sh <站点>`，最后 `scripts/pool-remove.sh <站点>`。站点还切着的服务器上后两个脚本会拒绝执行。

### 6. 升级镜像（改动：这台上已经切到 8.5 的站点会中断几秒）

摘掉这台的流量，拿到新镜像（同第 2 步），把 `.env` 里的 `IMAGE` 改成新标签，然后
`scripts/deploy.sh ghcr.io/huangsen365/php85-sidecar:<新标签>`。回滚是把 `IMAGE` 改回旧标签再执行一次。一台一台做。

### 7. Composer

```bash
docker exec -it -u sshuser -w /var/www/<站点目录> php85-sidecar composer install --no-dev
```

以 sshuser 运行，文件属主才对。镜像里没有 git，只能装 dist 包。默认走腾讯云镜像，换镜像的办法见 README。

## 排查

| 现象 | 先看 |
|---|---|
| 切换后 502 / 503 | `scripts/site-status.sh <站点>`；`docker ps` 看 sidecar 是否在跑；`tests/smoke.sh` |
| 切换后 500 | `$LOG_DIR/<站点>-error.log`。多半是代码在 8.5 下的问题：先回滚，把报错给开发 |
| `File not found` / `Primary script unknown` | sidecar 里的 `/var/www` 和老容器的不是同一个目录：核对 `.env` 的 `WWW_DIR` |
| 已登录用户掉线 | `PHP74_LIB_DIR` 不是 php74 的 session 目录，见预检的 WARN |
| 文件写不进去 | 池用户不是 1000:1000，见预检 |
| 发了业务请求，`accepted conn` 却只涨了查询的次数 | 这台没有 `.inc`，或者 httpd 没有重载：看 `scripts/site-status.sh` 的第一行 |
| 某个函数突然能用或不能用了 | `disable_functions` 在 8.5 这边是全局一份，见 README「与 php74 的差异」 |

## 汇报

每完成一步，用几句话告诉用户：在哪台服务器上做了什么、检查结果是什么、怎么撤销、下一步是什么。整件事做完后
列出：哪些站点在哪些服务器上已经是 8.5、还没做的服务器、留下的备份位置（`backup/`、`staging/`）。

## 演练

在一台测试机上（不是跑真实站点的服务器）可以把上面的流程先完整走一遍，做法和注意事项见 README「先演练一遍」：

```bash
tests/playground.sh up          # 打印老容器名、站点、镜像名、验证用的 curl 命令
# 然后做上面的 1、3、4、5：站点名 test.local，代码目录 test.local/public
tests/playground.sh status      # 站点地址和它现在的应答
tests/playground.sh down        # 清掉演练环境、演练部署的 sidecar、.env、staging/、backup/、日志
```

演练环境里要知道的：

- 验证用 `up` 打印的 `curl -s http://<地址>/index.php`（只有 http，只能在测试机本机访问）。每次应答的 `php` 都是
  8.5；切换前 `memory_limit` 是 128M（php74 的替身），切换后是 512M（站点的 8.5 池）。
- `lint-compare.sh` 会报一个 `NEW-8.5` 文件 `./legacy.php`，是故意放的，没有页面用它，告诉用户后继续。
- 做完一定执行 `tests/playground.sh down`。演练留下的 `.env` 如果被带到生产服务器上，`deploy.sh` 会照着它去找一个
  不存在的老容器。
