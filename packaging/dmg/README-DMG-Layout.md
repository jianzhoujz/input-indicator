## VS Code DMG 布局配置参考

以下是从 VS Code macOS DMG 中提取的布局参数，可用于制作你自己的 DMG 安装包。

### 文件清单

| 文件 | 说明 |
|------|------|
| `background.tiff` | 原始背景图（多分辨率 TIFF，含 1x 和 2x） |
| `background_1x.png` | 1x 背景图 480x320 @72dpi |
| `background_2x.png` | 2x Retina 背景图 960x640 @144dpi |
| `DS_Store` | Finder 布局配置文件（图标位置、窗口大小等） |
| `VolumeIcon.icns` | DMG 卷图标 |

### 窗口配置

```
窗口位置:  x=100, y=400
窗口大小:  480 x 352 (宽 x 高)
图标大小:  80px
网格间距:  100px
文字大小:  12pt
标签位置:  图标下方
背景类型:  自定义图片 (.background.tiff)
```

### 图标位置

```
你的App.app    →  (120, 160)   左侧
Applications   →  (360, 160)   右侧
```

两个图标等高排列（y=160），水平间距 240px。

### 隐藏的 UI 元素

侧边栏、工具栏、状态栏、路径栏、标签视图、预览面板均已隐藏，呈现干净的安装引导窗口。

### 如何复用到你的应用

1. **替换背景图**: 制作你自己的 480x320 (1x) 和 960x640 (2x) 背景图，用 `tiffutil -cathidpicheck bg_1x.tiff bg_2x.tiff -out .background.tiff` 合成多分辨率 TIFF。

2. **推荐使用工具创建 DMG**:
   - [create-dmg](https://github.com/create-dmg/create-dmg) — Shell 脚本工具
   - [node-appdmg](https://github.com/LinusU/node-appdmg) — Node.js 工具
   - [dmgbuild](https://github.com/dmgbuild/dmgbuild) — Python 工具

3. **示例 (create-dmg)**:
   ```bash
   create-dmg \
     --volname "Your App" \
     --volicon "VolumeIcon.icns" \
     --background "background.tiff" \
     --window-pos 100 400 \
     --window-size 480 352 \
     --icon-size 80 \
     --icon "Your App.app" 120 160 \
     --app-drop-link 360 160 \
     --no-internet-enable \
     "YourApp.dmg" \
     "source_folder/"
   ```

4. **示例 (appdmg JSON)**:
   ```json
   {
     "title": "Your App",
     "icon": "VolumeIcon.icns",
     "background": "background.tiff",
     "icon-size": 80,
     "window": {
       "position": { "x": 100, "y": 400 },
       "size": { "width": 480, "height": 352 }
     },
     "contents": [
       { "x": 120, "y": 160, "type": "file", "path": "Your App.app" },
       { "x": 360, "y": 160, "type": "link", "path": "/Applications" }
     ]
   }
   ```
