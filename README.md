# php85-sidecar

在 CentOS 7 老容器（Remi 在 EL7 上最高只有 php83）旁边，加一个 PHP 8.5 的 php-fpm 小容器。

- 老容器不动。vhost（`conf2.d`，NAS 上两台共用）里只预先加一行 `IncludeOptional conf.d/php85-<站点>*.inc`，平时什么也不做。
- 哪台服务器的老容器 `conf.d`（每台自己的）里放了这个站点的 `.inc`，哪台就把这个站点的 PHP 交给 8.5；删掉它再 graceful 就是回滚。所以可以一台一台切。
- 文中的 web001/002 是服务器的示例名（两台，共用一个 NAS），www.example.com 是站点的示例名。已用在两组这样的服务器上：一组把老站点从 php74 切到 8.5；另一组直接上只跑 8.5 的新站点，老容器端口从 7411 起。

## 适用环境

这个工具是为下面这种环境做的。拿不准就先跑预检，它只读，不改任何东西：

```bash
scripts/preflight.sh      # 结尾是 RESULT: OK 或 WARN 才往下做；FAILED 会说明差在哪里
```

- 宿主机：x86_64，有 Docker 和 compose 插件（`docker compose version` 有输出）。CentOS 7（内核 3.10）可以。
- 老容器：Apache httpd 2.4（带 `mod_proxy_fcgi`）加 Remi 的 php74（`/opt/remi/php74`、`/etc/opt/remi/php74`）。
- 每个站点一个 php-fpm 池：池名是 `<站点>-php74`，监听 `127.0.0.1:7401` 到 `7419`。
- vhost 用 `ProxyPassMatch ^/(.*\.php(/.*)?)$ fcgi://127.0.0.1:74NN/...` 把 PHP 交给池。
- 池以 uid 1000、gid 1000 的用户运行（镜像里叫 sshuser），apache 组是 48。
- `/var/www`、vhost 目录是从宿主机挂进老容器的。php74 的 session 目录（`/var/opt/remi/php74/lib/php`）最好也是，否则站点切换时已登录的用户会掉线。

预检会列出哪些站点池能直接迁、哪些不能，并给出这台机器的 `.env`。常见的不能直接迁的情况：池监听 unix socket、端口不在 7401–7419、池用户不是 1000:1000。这些要改脚本或镜像，不在开箱即用的范围内。

镜像的时区固定为 `Asia/Shanghai`（站点池自己设的 `date.timezone` 照常生效）。构建时默认走阿里云的软件源（`Dockerfile` 里的 `MIRROR`），composer 默认走腾讯云镜像，换法见「Composer」。

## 获取镜像

每个发行版都提供同一个镜像的两种形式，标签是 `<PHP 版本>-<构建日期>`：

```bash
# 1. 服务器能访问 ghcr.io
docker pull ghcr.io/huangsen365/php85-sidecar:<标签>
# 2. 访问不了：从 Release 页面下载离线包和校验文件，传到服务器上
sha256sum -c php85-sidecar_<标签>.tar.gz.sha256 && gunzip -c php85-sidecar_<标签>.tar.gz | docker load
```

两种方式得到的镜像名相同，`.env` 里的 `IMAGE` 写 `ghcr.io/huangsen365/php85-sidecar:<标签>`。也可以自己构建，见「构建与测试」。

## 交给 AI 来做

仓库里带了给 AI 助手的操作说明。Claude Code、Codex 这类能在终端里执行命令的助手都可以用：

1. 在目标服务器上（或者一台能 SSH 到它的机器上）克隆本仓库，在仓库目录里启动 AI 助手。
2. 告诉它要做什么，例如：「按这个仓库的说明，先预检这台服务器，再部署 PHP 8.5 sidecar，然后把 www.example.com 切到 8.5」。
3. 它先读 `AGENTS.md`，再按 `.claude/skills/php85-sidecar/SKILL.md` 一步步做：先做只读的预检；每个会改动服务器的步骤都先说明要改什么、怎么回滚，等你确认后再执行。

Claude Code 会自动发现 `.claude/skills/` 下的技能。想在别的目录里也能用，把 `.claude/skills/php85-sidecar` 复制到 `~/.claude/skills/` 下。

下面各节是同一套步骤的人工版本，也是 AI 执行时的依据。

## 先演练一遍

不想第一次就在生产服务器上做，可以在一台测试机上起一个演练环境。不要用跑着真实站点的服务器。测试机需要有 Docker、已经有 sidecar 镜像（见「获取镜像」），并且能联网构建一次演练用的老容器（要拉 `centos:7` 镜像，并从 mirrors.aliyun.com 装 httpd）。

```bash
tests/playground.sh up        # 起一个老容器形态的环境，里面有一个站点 test.local，并提示下一步
# 然后照「部署到一台服务器」和「把一个站点切到 8.5」做一遍：站点名 test.local，代码目录 test.local/public
tests/playground.sh status    # 随时看站点地址和它现在的应答
tests/playground.sh down      # 演练完清理：演练环境、演练时部署的 sidecar、.env、staging/、backup/、日志
```

演练环境和线上的三点不同：

- **没有真的 php74。** 站点切换前由一个替身池应答，切换后由站点自己的 8.5 池应答。两边返回的 `php` 都是 8.5，区别看 `memory_limit`：替身是 128M，站点的 8.5 池是 512M。
- **站点只有 http，只能在测试机本机访问。** 验证用 `up` 和 `status` 打印的那条 `curl -s http://<老容器的地址>/index.php`，不是下文的 https 命令。
- **有一个故意放的坏文件。** `test.local/public/legacy.php` 在 PHP 8 下编译不过，用来让 `lint-compare.sh` 有一条 `NEW-8.5` 可看。没有页面用到它，继续往下做即可。

流程、脚本和线上完全一样。演练用过的目录不要直接拿去生产用：先 `tests/playground.sh down`，确认目录里没有 `.env`。

## 设计

| 项 | 做法 |
|---|---|
| 镜像 | AlmaLinux 9 + Remi 的 php85。目录结构和老容器一样（`/opt/remi/php85`、`/etc/opt/remi/php85`） |
| 扩展 | `packages.txt` 对齐 php74，对比基准是 `baseline/php74-modules.txt`。没装的写在 `baseline/expected-missing.txt`：apc、propro（PHP 8 已经没有了），oci8、PDO_OCI（需要 Oracle 客户端，哪个站点要用再加） |
| 用户 | 所有进程都以 sshuser（1000:1000，附加组 apache 48）运行，和老容器的进程池一致。根文件系统只读，不给任何特权（capability） |
| 端口 | `8500`：内置的 www 池，只用于健康检查和自检，不接业务。`85NN`：站点池，与老容器的 `74NN` 一一对应。支持 `7401-7419` → `8501-8519`。端口只发布在 docker0 的 `172.17.0.1:8500-8519` 上，外网访问不到 |
| 网络 | 使用默认的 docker0 网桥（`network_mode: bridge`），不新建 compose 网络，避免占用新的 172.x 网段 |
| 挂载 | 和老容器使用相同的路径：`/var/www`，以及 `/var/opt/remi/php74/lib/php`（session 和 wsdl 缓存）。站点切换后，已登录的用户不会掉线。站点池目录在 `POOL_DIR`（NAS，两台共用）。日志在 `LOG_DIR`（各台本机） |
| 资源 | 不限制 CPU 和内存，和老容器一样。容量由各站点池的 `pm.max_children` 控制，数值照抄 php74 的池 |
| 切换 | httpd 按配置顺序取第一条匹配的 `ProxyPassMatch`。`.inc` 里那条指向 `172.17.0.1:85NN`，排在原来指向 `127.0.0.1:74NN` 的那条前面，所以有 `.inc` 的服务器先命中它。`gitpull.php` 那一行在 include 之前，不受影响 |
| git | 镜像里不装 git。`gitpull.php` 那一行继续走老容器的 `74NN`（老容器用 git 1.8，不会遇到新版 git 的 dubious ownership 问题） |
| composer | 镜像里带固定版本的 composer（`Dockerfile` 里的 `COMPOSER_VERSION` + `COMPOSER_SHA256`），用 `composer` 命令（`conf/composer`）运行，见下面「Composer」 |

## 构建与测试（在构建机上）

```bash
./build.sh --save      # 生成 php85-sidecar:<版本>-<日期> 和 dist/*.tar.gz(.sha256)；加 --fresh 不用构建缓存，装到最新的软件包
tests/e2e.sh           # 完整测试，最后必须输出 RESULT: OK；结束后会清理它启动的所有东西
```

`tests/e2e.sh` 会依次做这些事：

1. 用 `scripts/pool-from-php74.sh` 把一个 php74 格式的池转换成 8.5 的池。
2. 起一个 CentOS 7 的 httpd 2.4.6 容器当老容器（和老容器同版本，`tests/e2e/httpd-el7`），vhost 和 php74 池文件用服务器上的写法。跑预检，再用 `scripts/deploy.sh` 部署 sidecar（写 `.env`、启动、`tests/smoke.sh`、检查连通）。
3. 用和线上同一批脚本，按下面「把一个站点切到 8.5」的做法走一遍：lint 对比、建池、暂存和测试 vhost、换上 vhost（没有 `.inc` 时行为不变）、切换（PHP 到 8501，`gitpull.php` 仍在老池）、回滚（回到老池），最后是两个撤销脚本。sidecar 的 www 池（8500）在这里扮演老的 74NN 池。
4. 验证 session、站点池参数、错误日志、池状态页，以及能否读取 php74 写入的 session。
5. 端口 7411 → 8511 的转换和 8519 的发布；composer 以 sshuser 在站点目录里装一个包（经腾讯云镜像下载 zip；阿里云的 composer 镜像 2026 年已停更）、跑一个 script，文件属主是 1000:1000。这一步要能访问 mirrors.tencent.com。

## 部署到一台服务器

多台服务器共用存储（NAS）时一台一台部署，例子里是先 web001 再 web002。站点按服务器切换，只有部署了 sidecar 的服务器才能放 `.inc`。

把本仓库放到服务器的 `/root/php85-sidecar`，下面的命令都在这个目录里执行：

```bash
scripts/preflight.sh                                                 # 只读预检；FAILED 就先不要往下做，WARN 逐条看
# 镜像：docker pull 或加载离线包，见「获取镜像」
scripts/deploy.sh ghcr.io/huangsen365/php85-sidecar:<标签>           # 必须以 RESULT: OK 结束
```

`deploy.sh` 做这几件事，任何一步不通过就停下并说明原因：

1. 再跑一遍预检，按老容器的挂载写出 `.env`。已经有 `.env` 时原样使用，绝不覆盖；要重新生成就先把它挪走。
2. 建日志目录 `LOG_DIR`（属主 1000:1000）和池目录 `POOL_DIR`。
3. `docker compose up -d` 启动容器，跑 `tests/smoke.sh`。在 CentOS 7（内核 3.10）上第一次跑尤其要看。
4. 从老容器里连一次 sidecar 的 8500 端口，确认连得通。

有多个老容器时把名字放在后面：`scripts/deploy.sh <镜像> <老容器名>`。想手工写 `.env` 的话，照 `.env.example` 填好放在本目录，再执行 `deploy.sh`。

这一步只是多了一个容器，没有任何站点改用 8.5。撤掉：`docker compose down`。

## 把一个站点切到 8.5

站点用它在 php74 里的池名来指：池是 `[www.example.com-php74]`，站点名就是 `www.example.com`。先在一台服务器上切：通过负载均衡把这台的权重调成 0，用 hosts 指到这台来测试，没问题再放流量，然后做下一台。

每个脚本结尾输出 `RESULT: OK` 才做下一步。前四步不影响线上，第 5 步才真正切换。

| 步骤 | 命令 | 在哪些服务器上做 | 改动 |
|---|---|---|---|
| 1. 代码能不能在 8.5 下编译 | `scripts/lint-compare.sh <站点的代码目录>` | 一台 | 无，只读 |
| 2. 建 8.5 的池 | `scripts/pool-add.sh <站点>` | 每台有 sidecar 的 | 新增池文件，sidecar 平滑重载；站点仍在 php74 |
| 3. 准备 vhost | `scripts/vhost-stage.sh <站点>` | 每台 | 无，只写到 `staging/` 和 `backup/` |
| 4. 测试并换上 vhost | `scripts/vhost-test.sh <站点>`（每台），都通过后 `scripts/vhost-apply.sh <站点>` | 测试每台；vhost 在共用存储上时 apply 只做一次，否则每台 | vhost 多一行 include，没有 `.inc` 时不起作用；不重载 httpd |
| 5. 切换 | `scripts/site-switch.sh on <站点>` | 要切的那一台 | 这台放 `.inc`，httpd 平滑重载，这个站点的 PHP 改走 8.5 |
| 6. 验证 | `scripts/site-status.sh <站点>` 加上自己的业务测试 | 切了的那台 | 无，只读 |
| 回滚 | `scripts/site-switch.sh off <站点>` | 要退的那一台 | 删掉 `.inc`，httpd 平滑重载，回到 php74 |
| 撤销第 4 步 | `scripts/vhost-restore.sh <站点>` | 同 apply | vhost 换回 `backup/` 里的原文件；不重载 httpd |
| 撤销第 2 步 | `scripts/pool-remove.sh <站点>` | 每台有 sidecar 的 | 池文件移到 `backup/`，sidecar 平滑重载 |

说明：

1. **代码兼容性。** 先由开发确认这个站点的代码能在 PHP 8.5 下运行，或者就用摘掉流量的那台来测。`lint-compare.sh` 用 8.5 把整个代码目录编译一遍，再拿老容器的 php74 对比：标 `NEW-8.5` 的是 8.5 才有的问题（例如 `$s{0}` 这种花括号取字符，PHP 8.0 起是语法错误），标 `also-7.4` 的是本来就坏的文件。运行时才暴露的问题（被移除的函数、行为变化）lint 查不出来，只能靠测试和错误日志 `$LOG_DIR/<站点>-error.log`。
2. **池。** `pool-add.sh` 把 php74 的池原样转成 8.5 的池（`scripts/pool-from-php74.sh`：参数和 session 目录不变，端口 `74NN` 变 `85NN`），先用 `php-fpm -t` 检查，再给 sidecar 发 USR2 平滑重载，最后跑 `tests/smoke.sh`。池文件已经存在就不再生成，只加载。
3. **vhost。** `vhost-stage.sh` 找到把 PHP 交给这个池的那个 vhost 文件，生成加了 include 行的版本和这台的 `.inc`，并打印差异，线上文件不动。include 行插在 `gitpull.php` 那一行之后、PHP 那一行之前。
4. **测试。** `vhost-test.sh` 在老容器里用一份指向临时目录的 httpd.conf 检查两遍：没有 `.inc` 时（还没切的服务器会这样读）和有 `.inc` 时。再往 `.inc` 里加一行错误的指令，检查必须失败，证明 include 确实生效。vhost 在共用存储上时，有语法错误会让所有服务器的下一次 reload 失败，所以每台都要先测。`vhost-apply.sh` 用一次改名换上新 vhost，再在这台老容器里 `httpd -t`，不通过就自动换回原来的。
5. **切换。** `site-switch.sh on` 把 `.inc` 放进这台老容器的 `conf.d`，`httpd -t` 不通过就取出来，通过才平滑重载 httpd。php74 的 php-fpm 从不重载（重载它会打断所有站点正在处理的请求）。
6. **验证。** `curl -sk --resolve www.example.com:443:<这台的公网 IP> https://www.example.com/` 加上业务测试。`site-status.sh` 显示这台有没有切、池状态里的 `accepted conn` 和错误日志的最后几行。`accepted conn` 是这个池处理过的请求数，脚本自己每查一次也会让它加 1，所以要看它是不是比你查的次数涨得多：发几个业务请求，再查一次。

**回滚（这台）：** `scripts/site-switch.sh off <站点>`。这一条就让站点回到 php74，vhost 里那一行和 8.5 的池都可以留着，不起作用。

想连前面的准备也撤掉：先在所有服务器上 `site-switch.sh off`，再 `scripts/vhost-restore.sh <站点>` 把 vhost 换回原文件，最后 `scripts/pool-remove.sh <站点>` 去掉池。这两个脚本在站点还切着的服务器上会拒绝执行。

不用脚本、手工做的话，三个底层脚本可以单独用，用法见各自文件头：`scripts/pool-from-php74.sh`、`scripts/vhost-add-include.sh`、`scripts/site-inc.sh`。

## Composer

站点目录属 sshuser，composer 也以 sshuser 运行，装出来的 `vendor/` 属主不会错。NAS 两台共用，装一次两台都能用：

```bash
docker exec -it -u sshuser -w /var/www/<站点> php85-sidecar composer install --no-dev
```

- `conf/99-sidecar.ini` 的 `disable_functions` 对命令行也生效，里面的 `proc_open`、`popen`、`putenv` 是 composer 要用的。`composer` 这个包装命令只给它这一个 php 进程清空列表（`-d disable_functions=`），站点池不受影响。
- 镜像里没有 git，依赖只能用 dist（zip）安装；只能从 git 源码装的包会失败。默认源是腾讯云镜像（`conf/composer-config.json`），项目自己的 `repositories` 照常生效。
- 缓存在 `/tmp`（tmpfs），容器重启后清空。

## 升级镜像

1. 拿到新标签的镜像（`docker pull` 或离线包，见「获取镜像」；自己构建的话在构建机上 `./build.sh --save`），加载到每台服务器。
2. 改 `.env` 里的 `IMAGE`，执行 `scripts/deploy.sh <新镜像>`（它会重建容器、跑冒烟测试、检查连通）。重建容器期间，8.5 上的站点会有几秒钟的 502，所以要像打系统补丁那样，通过负载均衡摘掉流量，一台一台做。
3. 回滚：把 `IMAGE` 改回旧标签，再执行 `scripts/deploy.sh <旧镜像>`。

## 与 php74 的差异，切换前要知道

- `mongodb` 扩展从 1.13 升到 2.x，composer 里的 `mongodb/mongodb` 也要升到 `^2`。
- `imagick` 用的是 ImageMagick 6.9，和 php74 的主版本相同。
- `disable_functions` 在 sidecar 里是全局的一份，各池不能自己设：PHP 8.4 起同一个 master 下列表不同的池共用 opcache 会调错函数（[php-src#24661](https://github.com/php/php-src/issues/24661)，未修复）。全局列表取 web001/002 所有 php74 站点池的交集，所以原来另外禁了 `scandir`/`opendir` 的站点在 8.5 上这两个函数可用；`pool-from-php74.sh` 会在 stderr 列出来。确需更严的站点，单独起第二个 sidecar（另一组端口、另一份 ini）。
- 全局 `expose_php = Off`，响应里不再带 `X-Powered-By: PHP/...` 头。
- Remi 用 2021 年的密钥（`B19527F1478F8947`）签名 EL9 的包；阿里云镜像上没有这个密钥文件，所以构建时从 rpms.remirepo.net 获取。

## 版本

- 发行版的版本号就是镜像标签：`<PHP 版本>-<构建日期>`。每个发行版在 Release 页面写明 PHP 版本和变化。
- 要拿到 PHP 的安全更新，就升级到新标签的镜像，做法见「升级镜像」。
- 镜像里的软件来自 AlmaLinux 9、EPEL、Remi 的仓库和 getcomposer.org，各自遵循自己的许可证。

## 免责声明

这些步骤会改动生产服务器上的 Apache 配置，并让线上站点换一个 PHP 版本运行。请先在摘掉流量的一台服务器上验证，保留备份，并确认回滚办法可用。本项目按 Apache License 2.0 以「现状」提供，不附带任何担保，使用后果由使用者自行承担。

## 反馈

问题和建议请提到本仓库的 Issues。请不要在里面贴域名、IP、密码等敏感信息。

## 许可证

[Apache License 2.0](LICENSE)。
