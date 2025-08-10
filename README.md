好的，这是一个为你的通用备份脚本设计的 `README.md` 文件。它包含了简单的介绍、特性列表、使用说明以及所有配置变量的详细解释。

---

# Generic Server Data Backup Script

![Bash](https://img.shields.io/badge/Shell_Script-Bash-blue?style=for-the-badge&logo=gnu-bash)
![Rclone](https://img.shields.io/badge/Rclone-Cloud_Sync-orange?style=for-the-badge&logo=generic)
![Zip](https://img.shields.io/badge/Compression-Zip-green?style=for-the-badge&logo=zip)
![License](https://img.shields.io/github/license/YOUR_USERNAME/YOUR_REPO_NAME?style=for-the-badge)

## 简介

这个 Bash 脚本是一个通用的、自动化的服务器数据备份解决方案。它旨在简化在 Linux 服务器上定期备份关键应用程序或服务数据的过程。脚本会压缩并加密指定的源目录，然后使用 `rclone` 将备份文件同步到远程存储（例如 AWS S3、R2、Google Drive 等）。

为了提高用户友好性，脚本还包含了自动检测和安装所需依赖（`zip` 和 `rclone`）的功能。通过少量配置，您可以轻松地将此脚本适配到您的不同项目或服务的数据备份需求中。

## 主要特性

*   **通用性：** 通过配置 `PROJECT_NAME` 变量，轻松适配不同的项目或应用程序。
*   **自动化依赖管理：** 自动检测并安装 `zip` 和 `rclone`，支持 `apt`、`yum` 和 `dnf` 包管理器。
*   **数据加密：** 使用 `zip` 的内置加密功能，确保传输和存储的数据安全（需提供环境变量密码）。
*   **远程同步：** 利用 `rclone` 强大的同步功能，将备份数据可靠地传输到各种云存储服务。
*   **详细日志：** 将所有操作和错误信息记录到日志文件，方便审计和问题排查。
*   **错误处理：** 关键步骤失败时立即退出，并记录详细错误信息。
*   **临时文件清理：** 备份完成后自动删除本地生成的临时加密文件。

## 使用方法

### 1. 克隆或下载脚本

将脚本文件下载到您的服务器上，例如 `/opt/backup_scripts/` 目录。

```bash
# 创建目录（如果不存在）
sudo mkdir -p /opt/backup_scripts/

# 通过 wget 下载脚本（假设文件名为 generic_backup.sh）
sudo wget -O /opt/backup_scripts/generic_backup.sh https://github.com/YOUR_USERNAME/YOUR_REPO_NAME/raw/main/generic_backup.sh

# 或者，如果您已经克隆了整个仓库
# sudo cp generic_backup.sh /opt/backup_scripts/
```

### 2. 设置执行权限

```bash
sudo chmod +x /opt/backup_scripts/generic_backup.sh
```

### 3. 配置 Rclone

如果您尚未配置 Rclone，您需要手动配置您的远程存储。脚本将使用您的 Rclone 配置中名为 `R2` 的远程连接。

```bash
rclone config
```

按照提示完成配置。例如，如果您要连接 Cloudflare R2，选择 `s3` 类型并按照 R2 的文档进行配置。确保您选择的远程名称与脚本中 `RCLONE_TARGET` 变量（例如 `R2`）一致。

### 4. 编辑脚本配置

打开 `generic_backup.sh` 文件，并根据您的项目需求修改 `Configuration Section` 中的变量。

```bash
sudo nano /opt/backup_scripts/generic_backup.sh
```

**最重要的变量是 `PROJECT_NAME` 和 `SOURCE_DIR`。**

### 5. 设置加密密码环境变量

**强烈推荐通过环境变量而非硬编码方式提供加密密码**。这样可以避免密码直接出现在脚本文件中。

在运行脚本或配置定时任务时，将密码作为环境变量传递。

```bash
# 手动测试运行示例
sudo ENCRYPTION_PASSWORD="YourStrongEncryptionPassword" /opt/backup_scripts/generic_backup.sh

# 配置 Cron Job 时（见下一步）
# 0 3 * * * ENCRYPTION_PASSWORD="YourStrongEncryptionPassword" /opt/backup_scripts/generic_backup.sh >> /dev/null 2>&1
```

### 6. 配置定时任务 (Cron Job)

建议使用 `root` 用户的 Cron 表来运行此脚本，因为它需要 `root` 权限来安装依赖和访问某些目录。

```bash
sudo crontab -e
```

添加一行到文件中，例如每天凌晨 3 点执行备份：

```cron
# 每天凌晨 3 点执行 'Moontv' 项目备份
0 3 * * * ENCRYPTION_PASSWORD="YourSecretMoontvPassword" /opt/backup_scripts/generic_backup.sh >> /dev/null 2>&1

# 如果是另一个项目，例如 'CRM'，您可以复制脚本并修改 PROJECT_NAME
# 假设您已将脚本复制并修改为 backup_crm.sh
# 每天凌晨 4 点执行 'CRM' 项目备份
0 4 * * * ENCRYPTION_PASSWORD="YourSecretCRMPassword" /opt/backup_scripts/backup_crm.sh >> /dev/null 2>&1
```

`>> /dev/null 2>&1` 将脚本的所有输出重定向到 `/dev/null`，避免 Cron 发送邮件。所有日志都会写入 `LOG_FILE`。

## 配置变量详解

以下是脚本中 `Configuration Section` 的详细说明：

| 变量名                | 描述                                                                                                                                              | 默认值/示例            |
| :-------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------ | :--------------------- |
| `PROJECT_NAME`        | **必填。** 定义项目的名称。此名称用于日志文件、备份文件和 Rclone 目标路径，也会出现在日志消息中。**此为脚本适配不同项目的核心变量。**              | `"Moontv"`             |
| `LOG_FILE`            | 备份操作的日志文件完整路径。文件命名会包含 `PROJECT_NAME` 的小写形式，例如 `/var/log/moontv_backup.log`。每次执行都会追加日志。                     | `"/var/log/${PROJECT_NAME,,}_backup.log"` |
| `SOURCE_DIR`          | **必填。** 待备份的源目录的完整路径。默认根据 `PROJECT_NAME` 的小写形式生成（例如 `/moontv`），**如果您的源代码目录不同，请务必手动调整此值。** | `"/bash/${PROJECT_NAME,,}"` |
| `TEMP_BACKUP_DIR`     | 备份文件 (`.zip`) 的临时存放目录。脚本会在需要时自动创建此目录。确保此目录有足够的磁盘空间和写入权限。                                            | `"/var/backups"`       |
| `CURRENT_ZIP_FILE`    | 生成的加密压缩文件的完整路径及文件名。文件命名会包含 `PROJECT_NAME` 的小写形式，例如 `/var/backups/moontv_data.zip`。                             | `"${TEMP_BACKUP_DIR}/${PROJECT_NAME,,}_data.zip"` |
| `RCLONE_TARGET`       | `rclone` 远程存储的目标路径。格式为 `<Rclone远程名称>:/<目标路径>`。例如，如果您在 `rclone config` 中配置了一个名为 `R2` 的远程连接。 | `"R2:/backup/${PROJECT_NAME,,}"` |
| `REQUIRED_DEPS`       | 脚本运行所需的核心依赖（命令）列表，默认为 `zip` 和 `rclone`。                                                                                   | `("zip" "rclone")`     |
| `ENCRYPTION_PASSWORD` | **环境变量。** 备份文件加密所需的密码。**此密码必须通过环境变量传递给脚本，切勿硬编码在脚本文件内。**                                          | N/A (通过环境变量设置) |

## 日志文件

所有备份操作的输出都会被重定向到 `${LOG_FILE}`。您可以定期检查此文件来监控备份状态和排查问题。

```bash
sudo tail -f /var/log/moontv_backup.log
```

## 注意事项

*   **权限：** 脚本需要足够的权限来读写 `SOURCE_DIR`、`TEMP_BACKUP_DIR` 和 `LOG_FILE`，以及执行 `apt`/`yum`/`dnf` 命令进行依赖安装。通常以 `root` 用户运行是最简单的方案。
*   **Rclone 配置：** `rclone config` 必须在脚本运行的用户环境下完成配置。脚本本身不会自动配置 Rclone 远程连接。
*   **密码安全：** 务必通过环境变量传递 `ENCRYPTION_PASSWORD`，避免将敏感信息直接写入脚本文件或版本控制。
*   **磁盘空间：** `TEMP_BACKUP_DIR` 所在的磁盘分区需要有足够的空间来存放压缩后的备份文件，直到同步完成。

## 贡献

如果您有任何改进建议或发现 Bug，欢迎提交 Issue 或 Pull Request。

## 许可证

本项目采用 [MIT 许可证](LICENSE) 发布。

---

请记得将 `YOUR_USERNAME` 和 `YOUR_REPO_NAME` 替换为你的实际 GitHub 用户名和仓库名，并根据你的实际情况调整示例中的路径。
