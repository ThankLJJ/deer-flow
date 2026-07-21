# 前端 Excel 预览实现指南

> 本文档基于本项目 `frontend/src/components/workspace/artifacts/file-previews.tsx` 的真实实现整理而成。
> 解析使用 [SheetJS](https://sheetjs.com/)（npm 包名 `xlsx`），表格 UI 为自行渲染。

---

## 目录

- [技术方案概览](#技术方案概览)
- [1. 安装依赖](#1-安装依赖)
- [2. 完整组件代码](#2-完整组件代码)
- [3. 使用示例](#3-使用示例)
- [4. 准备测试文件](#4-准备测试文件)
- [5. 关键 API 速查](#5-关键-api-速查)
- [6. 项目中的真实实现](#6-项目中的真实实现)
- [7. 安全提示](#7-安全提示)

---

## 技术方案概览

| 项目 | 说明 |
|------|------|
| 解析库 | SheetJS（`xlsx`），版本 `^0.18.5` |
| 渲染方式 | 原生 `<table>` 自渲染，不依赖电子表格 UI 库 |
| 加载策略 | `await import("xlsx")` 动态导入，按需打包 |
| 支持格式 | `.xlsx` / `.xls` / `.csv` |
| 多 Sheet | ✅ 读取 `wb.SheetNames`，顶部 Tab 切换 |
| 图表 Sheet | ✅ 通过 `!ref` / `!chart` / `!drawing` 检测 |

**核心流程：**
```
fetch(url) → arrayBuffer → XLSX.read → 遍历 SheetNames → sheet_to_json(header:1)
→ 第一行作表头，其余作数据行 → 渲染 <table>
```

---

## 1. 安装依赖

```bash
pnpm add xlsx
# 或
npm install xlsx
# 或
yarn add xlsx
```

---

## 2. 完整组件代码

> 文件路径建议：`frontend/src/components/workspace/artifacts/ExcelPreview.tsx`

```tsx
"use client";

import { useEffect, useState } from "react";

// ---------------------------------------------------------------------------
// 单个 Sheet 的数据结构
// ---------------------------------------------------------------------------
interface SheetData {
  name: string;
  columns: string[];
  rows: string[][];
  rowCount: number;
}

// ---------------------------------------------------------------------------
// Excel / CSV 预览组件（多 Sheet 切换 + 原生表格渲染）
// 用法：<ExcelPreview url="/files/demo.xlsx" />
// ---------------------------------------------------------------------------
export function ExcelPreview({ url }: { url: string }) {
  const [sheets, setSheets] = useState<SheetData[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activeSheet, setActiveSheet] = useState(0);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        // 动态导入：只有真正预览时才把 xlsx 打进 bundle
        const XLSX = await import("xlsx");
        const res = await fetch(url);
        const buf = await res.arrayBuffer();
        const wb = XLSX.read(buf, { type: "array" });

        if (!wb.SheetNames.length) throw new Error("No sheets found");

        const parsed: SheetData[] = wb.SheetNames.map((name) => {
          const ws = wb.Sheets[name]!;
          if (!ws["!ref"]) {
            return { name, columns: [], rows: [], rowCount: 0 };
          }
          // header: 1 => 输出二维数组（每行一个数组），defval 兜底空单元格
          const json = XLSX.utils.sheet_to_json<string[]>(ws, {
            header: 1,
            defval: "",
          });
          const columns = (json[0] ?? []).map(String);
          const rows = json.slice(1).map((r) => r.map(String));
          return { name, columns, rows, rowCount: rows.length };
        });

        if (!cancelled) setSheets(parsed);
      } catch (e: unknown) {
        if (!cancelled)
          setError(e instanceof Error ? e.message : "Failed to load");
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [url]);

  if (error)
    return <div style={{ padding: 16, color: "red" }}>{error}</div>;
  if (!sheets)
    return <div style={{ padding: 32, textAlign: "center" }}>加载中…</div>;

  const current = sheets[activeSheet] ?? sheets[0];
  if (!current) return <div style={{ padding: 16 }}>No sheets found</div>;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      {/* Sheet 切换 Tab */}
      {sheets.length > 1 && (
        <div
          style={{
            display: "flex",
            gap: 4,
            overflowX: "auto",
            borderBottom: "1px solid #eee",
            background: "#fafafa",
            padding: "4px 8px",
          }}
        >
          {sheets.map((s, i) => (
            <button
              key={s.name}
              onClick={() => setActiveSheet(i)}
              style={{
                flexShrink: 0,
                padding: "4px 12px",
                fontSize: 12,
                borderRadius: 6,
                border: "none",
                cursor: "pointer",
                background: i === activeSheet ? "#fff" : "transparent",
                boxShadow:
                  i === activeSheet ? "0 1px 2px rgba(0,0,0,.08)" : "none",
              }}
            >
              {s.name}
              <span style={{ marginLeft: 6, color: "#999", fontSize: 10 }}>
                ({s.rowCount})
              </span>
            </button>
          ))}
        </div>
      )}

      {/* 表格内容 */}
      <div style={{ flex: 1, overflow: "auto" }}>
        {current.columns.length === 0 ? (
          <div style={{ padding: 32, textAlign: "center", color: "#999" }}>
            空 Sheet
          </div>
        ) : (
          <table
            style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}
          >
            <thead>
              <tr>
                {current.columns.map((c, i) => (
                  <th
                    key={i}
                    style={{
                      position: "sticky",
                      top: 0,
                      background: "#f5f5f5",
                      borderBottom: "1px solid #ddd",
                      padding: "8px 12px",
                      textAlign: "left",
                      whiteSpace: "nowrap",
                    }}
                  >
                    {c}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {current.rows.map((row, ri) => (
                <tr key={ri} style={{ borderBottom: "1px solid #f0f0f0" }}>
                  {row.map((cell, ci) => (
                    <td
                      key={ci}
                      style={{ padding: "6px 12px", whiteSpace: "nowrap" }}
                    >
                      {cell}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
```

---

## 3. 使用示例

```tsx
import { ExcelPreview } from "./ExcelPreview";

export default function Demo() {
  return (
    <div style={{ height: 600, border: "1px solid #eee", borderRadius: 8 }}>
      {/* 把 xlsx / xls / csv 文件放到 public/files/ 下即可 */}
      <ExcelPreview url="/files/demo.xlsx" />
    </div>
  );
}
```

---

## 4. 准备测试文件

在 `public/files/` 放任意一个 `.xlsx`（例如 `demo.xlsx`），内容示例：

| 姓名 | 年龄 | 城市 |
|------|------|------|
| 张三 | 28   | 北京 |
| 李四 | 34   | 上海 |

跑起来后，组件会：

1. `fetch` 拉取文件 → `arrayBuffer`
2. `XLSX.read` 解析出所有 Sheet
3. `sheet_to_json(ws, { header: 1 })` 把每个 Sheet 转成二维数组
4. 第一行当表头，其余当数据行渲染
5. 多 Sheet 时顶部出现切换 Tab

---

## 5. 关键 API 速查

| 用途 | 代码 |
|------|------|
| 动态导入（减小首屏体积） | `const XLSX = await import("xlsx")` |
| 解析二进制 | `XLSX.read(buf, { type: "array" })` |
| 转二维数组（首行作表头） | `XLSX.utils.sheet_to_json(ws, { header: 1, defval: "" })` |
| 判断 Sheet 是否为空 | `!ws["!ref"]` |
| 判断是否图表 Sheet | `!ws["!ref"] && (ws["!chart"] \|\| ws["!drawing"])` |
| 获取所有 Sheet 名 | `wb.SheetNames` |

---

## 6. 项目中的真实实现

本项目位于 `frontend/src/components/workspace/artifacts/file-previews.tsx`，
完整方案还包含以下几种文件预览，通过 `FilePreview` 统一分发：

| 类型 | 扩展名 | 解析/渲染 |
|------|--------|-----------|
| Excel | `xlsx` / `xls` / `csv` | SheetJS（`xlsx`）解析 + 原生表格 |
| DOCX | `doc` / `docx` | `mammoth` 转 HTML |
| Image | `png` / `jpg` / `gif` / `svg` / ... | `<img>` 原生 |
| PDF | `pdf` | `<iframe>` 浏览器原生 |

**分发逻辑：**
```ts
export type FilePreviewType = "excel" | "docx" | "image" | "pdf" | null;

export function getFilePreviewType(filepath: string): FilePreviewType {
  const ext = filepath.split(".").pop()?.toLowerCase() ?? "";
  if (["xlsx", "xls", "csv"].includes(ext)) return "excel";
  if (["doc", "docx"].includes(ext)) return "docx";
  if (["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico"].includes(ext))
    return "image";
  if (ext === "pdf") return "pdf";
  return null;
}
```

依赖声明见 `frontend/package.json`：
```json
{
  "xlsx": "^0.18.5",
  "mammoth": "^1.12.0"
}
```

---

## 7. 安全提示

⚠️ SheetJS npm 上的社区版 `xlsx@0.18.5` 存在已知漏洞：

- **CVE-2023-30533**：原型污染
- **CVE-2024-22363**：原型污染

官方修复版本只发布在 <https://cdn.sheetjs.com/>（当前 0.20.x+），
npm registry 上的版本未同步更新。

**建议：**
- 对安全有要求的项目，从官网安装最新版：
  ```bash
  npm i --save https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz
  ```
- 或评估替换为 `exceljs` 等替代库（注意 API 差异较大）。
- 本项目用于本地预览用户自己的文件、风险可控，可按需升级。
