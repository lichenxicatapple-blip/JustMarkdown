# JustMarkdown 品牌资产

标志为小写 `.md` 合字，保留加高的 d 竖笔与既定字形间距。SVG 使用独立轮廓，不依赖字体。

竖笔以母版坐标中的 98 为粗细基准，d 的字腹上下沿为 88，弧线按视觉重量校正。m 保留双拱的自然宽度；各字形共用基线，d 的高竖笔与 m 的端部采用相同圆角。

## 正式资产

| 文件 | 用途 |
| --- | --- |
| `mark.svg` / `mark.png` | 透明背景母版与栅格交付 |
| `app-icon-light.svg` / `.png` | 白底深字外观 |
| `app-icon-dark.svg` / `.png` | 深底浅字外观 |
| `mark-black.svg` / `.png` | 透明背景黑色版本 |
| `mark-white.svg` / `.png` | 透明背景白色版本 |
| `JustMarkdown.icon` | 直接参与 App 构建的 Icon Composer 图标包，包含浅色、深色与着色外观 |
| `exports.json` | 交付文件清单、尺寸与色彩空间 |
| `../approved-reference.png` | 已批准的视觉参考 |

## 修改与交付

1. 修改 `mark.svg` 并同步 `JustMarkdown.icon/Assets/01-Mark.svg`，保持合字比例、句点间距和 d 竖笔。
2. 在 Icon Composer 核对各外观。图标输入不烘焙圆角、阴影或高光，由系统处理外形。
3. 从对应 SVG 通过设计工具导出 PNG：1024 × 1024、sRGB，透明版本保留透明度。
4. 同步首页的 `JustMarkdown/Assets.xcassets/BrandMark.imageset/BrandMark.svg`。保留母版轮廓，将首页 SVG 的画布收至图形边界，避免图标画布的透明留白参与布局。提交母版、外观文件与 App 输入，核对首页标志和系统图标。

首页标志与 Icon Composer 图标是独立输入，更新其中一个不会自动更新另一个。
