# 阿里云 ECS / 轻量服务器 SSH 卡死、I/O wait 高自救脚本

这是一个面向阿里云 ECS / 轻量应用服务器的 Bash 脚本，用来缓解低基线云盘或突发型磁盘在高写入、元数据频繁更新、日志刷盘等场景下出现的 I/O 堵塞问题，减少 SSH 会话“卡住不返回”、系统响应变慢、`iowait` 偏高、磁盘 `%util` 打满、服务被拖慢甚至“假死”的情况。

脚本名称：`io-safe-auto.sh`

适合搜索这些问题时找到本项目：

- 阿里云服务器 SSH 卡死
- 阿里云轻量服务器 SSH 无响应
- Linux `iowait` 高 / `await` 高 / 磁盘 `%util` 100%
- `rm` 大目录后 SSH 卡住
- `tar` 解压、日志写入、`git clone` 后服务器变慢
- 阿里云云盘 I/O 堵塞 / Linux SSH 假死

关键词：`Aliyun`、`Alibaba Cloud`、`ECS`、`SSH hangs`、`iowait`、`await`、`nr_requests`、`sysctl`、`systemd`、`udev`

## 快速开始

```bash
curl -O https://raw.githubusercontent.com/tageecc/aliyun-io-safe/main/io-safe-auto.sh
chmod +x io-safe-auto.sh
sudo bash io-safe-auto.sh start
```

启用后建议断开并重新连接一次 SSH，让新会话继承新的 I/O 权重配置。

## 这个脚本解决什么问题

在一些阿里云低配实例或轻量服务器上，系统盘的 IOPS 和吞吐比较有限。一旦出现下面这些场景：

- 执行大量 `rm`、`tar`、`git clone`、日志写入或数据库刷盘
- 磁盘写回堆积，`dirty page` 长时间不能及时落盘
- 块设备请求队列堆满，普通 SSH 命令与系统服务一起排队
- 根分区频繁更新访问时间，进一步放大随机 I/O

就容易出现一种常见现象：

- SSH 已连上，但命令很久没输出
- `top`、`df`、`ls` 甚至 `bash` 本身都像“卡死”了一样
- 实例没有彻底宕机，但交互几乎不可用

这个脚本的目标不是提升磁盘性能上限，而是通过控制 I/O 堆积和会话优先级，让系统在磁盘吃紧时尽量“别彻底锁死”。

## 脚本做了什么

脚本会自动探测根分区所在物理盘、磁盘容量和当前 `nr_requests`，然后应用一组偏保守的 I/O 安全配置：

1. 调整内核脏页参数

- 降低 `vm.dirty_background_ratio` 和 `vm.dirty_ratio`
- 缩短写回周期，减少一次性堆积过多脏页
- 降低 `swappiness`，提高缓存回收压力控制

2. 优化根分区挂载参数

- 为根分区启用 `noatime,nodiratime`
- 减少每次访问文件/目录时产生的额外元数据写入

3. 限制块设备请求队列深度

- 自动读取根盘容量
- 基于容量动态计算一个更安全的 `nr_requests`
- 通过 `udev` 规则保证重启或设备变化后仍然生效

这一项是脚本的核心。对基线较低的系统盘来说，队列太深不一定更快，反而更容易把延迟越堆越高，最后表现成 SSH 假死和系统交互失灵。

4. 降低用户会话的 I/O 权重

- 给 `user.slice` 配置较低的 `IOWeight`
- 让 SSH 里跑的手工命令别和关键系统服务抢磁盘

这样在磁盘压力很大时，系统服务通常比交互会话更容易存活。

## 适用场景

推荐在以下环境中使用：

- 阿里云 ECS / 轻量应用服务器
- 根盘是性能较弱的云盘，容易被突发写入打满
- 经常通过 SSH 远程维护，最怕实例“没死但完全没法操作”

更适合“保命型调优”，不适合把它当成性能优化万能方案。如果你的业务长期稳定打满磁盘，根本解决办法仍然是升级磁盘规格、拆分数据盘、优化写入模式或引入限流。

## 常见搜索问题，对应看这里

如果你正在搜下面这些问题，这个脚本基本就是为这种场景准备的：

- “阿里云服务器 SSH 卡死，但机器没完全宕机”
- “阿里云轻量服务器一跑写盘任务就无响应”
- “Linux `iowait` 很高，`top`、`df`、`ls` 都卡”
- “磁盘 `await` 很高，`%util` 接近 100%”
- “删除大目录、解压文件、刷日志后 SSH 假死”

它的思路不是单纯提速，而是限制 I/O 堆积，把系统从“彻底拖死”拉回到“虽然慢，但还能连上 SSH 做处理”。

## 使用方法

### 1. 下载脚本

你可以直接在服务器下载：

```bash
curl -O https://raw.githubusercontent.com/tageecc/aliyun-io-safe/main/io-safe-auto.sh
```

也可以先克隆仓库：

```bash
git clone https://github.com/tageecc/aliyun-io-safe.git
cd aliyun-io-safe
```

如果你习惯本地上传，也可以用：

```bash
scp io-safe-auto.sh root@your-server:/root/
```

### 2. 赋予执行权限

```bash
chmod +x io-safe-auto.sh
```

### 3. 启用防卡死配置

```bash
sudo bash io-safe-auto.sh start
```

执行后脚本会：

- 自动识别根盘设备
- 计算安全的 `nr_requests`
- 写入 `sysctl`、`udev`、`systemd` 配置
- 重挂载根分区

建议启用后断开并重新连接一次 SSH，让新会话继承新的 I/O 权重配置。

### 4. 查看当前状态

```bash
sudo bash io-safe-auto.sh status
```

### 5. 恢复默认配置

```bash
sudo bash io-safe-auto.sh stop
```

恢复后建议重启一次实例，让部分内核状态彻底回到默认路径：

```bash
sudo reboot
```

## 推荐验证方式

可以用 `iostat` 观察根盘延迟和利用率：

```bash
iostat -x vda 1
```

如果你的根盘不是 `vda`，请把设备名替换成脚本实际探测到的名字，例如 `nvme0n1`、`xvda` 等。

重点关注这些指标：

- `await` 是否长期很高
- `%util` 是否接近 100%
- 在高压场景下，SSH 是否仍然能响应简单命令

## 配置落点

脚本会写入以下位置：

- `/etc/sysctl.d/99-io-safe.conf`
- `/etc/udev/rules.d/60-io-safe.rules`
- `/etc/systemd/system/user.slice.d/99-io-weight.conf`
- `/etc/fstab`（仅在缺少 `noatime` 时修改，并自动备份）
- `/var/lib/io-safe-auto/state.env`（保存启用前的设备与队列深度，便于回滚）

## 注意事项

- 必须使用 `root` 或 `sudo` 执行
- 会修改 `/etc/fstab`、`sysctl`、`udev` 和 `systemd` 配置
- 建议先在非核心生产实例验证
- 不同实例规格、云盘类型、内核版本，效果会有差异
- 如果你本身已经有更细粒度的 I/O 调优策略，请先审查是否会冲突
