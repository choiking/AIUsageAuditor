# ChatGPT Desktop AX 可行性调查

调查日期：2026-09-12。

本机环境：Apple Silicon；Xcode 26.5（17F42）；Apple Swift 6.3.2。读取安装包 Info.plist 后确认：

| 本机安装名称 | Bundle ID | 结果 |
| --- | --- | --- |
| ChatGPT.app | `com.openai.codex` | 实际为 Codex，不是此 MVP 的读取目标 |
| ChatGPT Classic.app | `com.openai.chat` | 真正的 ChatGPT Desktop，版本 1.2026.184 |

尝试使用当前环境的原生界面检查工具读取 `com.openai.chat`，工具返回“Computer Use is not allowed to use the app 'com.openai.chat' for safety reasons.” 因此未获取真实 AX 树，未发送测试消息，也未通过其他路径绕过该限制。

**结论：目前无法判断真实消息角色、会话 ID、正文节点及生成按钮是否稳定暴露。** 不把候选的 `user-message` / `assistant-message` identifiers 当成已确认的 ChatGPT 属性。

已完成的备用方案：

- `AXReader` 通过 macOS AX API 读取目标 bundle 的主窗口；可配置深度/节点预算、单次总时间预算；拒绝不完整快照。
- `ChatGPTMatcher` 与系统 AX 解耦，可以通过 JSON fixture、角色规则、正文范围规则独立校准。
- `AXInspector` 提供脱敏结构树、主动包含文本的树和 JSON 导出。
- 未发现稳定 document ID 时要求明确手动会话；不使用容易重名或自动更改的窗口标题做唯一 ID。

用户本机的后续验收：

1. 编译固定路径的 `.app`，自行授予辅助功能权限，并打开无敏感信息的测试会话。
2. 导出空聊天、发送后、流式生成中和完成后的 AX 树，检查 `AXIdentifier`、`AXDescription`、`AXTitle` 与 `AXDocument`。
3. 确认输入框被排除，已发消息拥有可辨认角色，正文子节点顺序符合显示顺序。
4. 检查代码块、列表、重复段落、中英文、相同 prompt 连发、停止/继续生成。
5. 检查新聊天、标题自动改名、返回旧聊天、滚动、分页、编辑与重生成。若 AX 无法可靠区分，应保留保守模式并记录漏计边界。
6. 校准配置，把脱敏真实 fixture 添加到测试。未完成这一步前，产品状态应为“AX adapter 待实机校准”。

## v0.2 Claude inspection and multi-app implementation

On 2026-09-12, the permitted native UI tool exposed an existing Claude Desktop conversation (`com.anthropic.claudefordesktop`). Its web area exposed a `claude.ai/chat/<id>` URL. The transcript used `Chat messages`, numbered `Message N of M` groups, and initial `You said:` / `Claude responded:` headings duplicating the opening text. Action toolbars, sidebar and draft editor were separate from message bodies.

The new Claude matcher uses this structure and excludes the duplicate role heading. Tests reproduce its shape using synthetic text; no real conversation text was saved to fixtures. No test prompt was sent. Generation-button labels remain candidates, and the Auditor's own permission, capture and streaming have not received end-to-end validation. The prior ChatGPT access restriction was not bypassed.

ChatGPT and Claude now have independent configuration, tracker, session, pause control and status. Their daily totals are shown separately and combined. The user must grant Accessibility access to the final app path and perform a live test as described in the README.
