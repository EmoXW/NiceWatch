# NiceWatch 图标

采用用户验收通过的 A 方形方案：珍珠白圆角方形底座、深海军蓝圆角正方形播放标记、白色播放键、珊瑚红更新点，底部带浅冰蓝反光。

- `AppIcon-master.png`：透明背景设计母版，由内置 imagegen 生成。
- `AppIcon.iconset/`：运行导出脚本生成的 16–1024 像素 PNG，作为中间产物不提交。
- `AppIcon.icns`：打包脚本使用的 macOS 应用图标。
- `MenuBar-preview.png`：实际绘制的菜单栏图标在深浅背景上的预览，左侧普通，右侧未读。
- 菜单栏由 `Sources/NiceWatch/IconArtwork.swift` 原生绘制为透明单色模板，随系统外观着色；未读点保持单色，保证小尺寸清晰。

重新导出应用图标：`python3 tools/build_icons.py`。构建脚本会把 ICNS 放进应用 Resources 并在 Info.plist 声明。

生成提示词：

> Create the FINAL production app icon asset from the approved NiceWatch A Revised design. One standalone square macOS app icon, centered, face-on, transparent background, no text. Pearly white rounded-square outer tile with soft sculpted depth and subtle icy blue light at bottom right; centered dark navy rounded SQUARE playback tile with white right-facing triangular play cutout; coral red circular update dot overlapping upper right with clean white separation ring. Match the approved reference, balanced geometry, transparent safe margin, crisp contours, restrained soft UI finish, no extra elements or perspective.
