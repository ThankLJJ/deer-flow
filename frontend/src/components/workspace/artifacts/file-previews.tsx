"use client";

import { useEffect, useState, useMemo } from "react";
import { LoaderIcon } from "lucide-react";

import { cn } from "@/lib/utils";

// ---------------------------------------------------------------------------
// Excel / CSV Preview (SheetJS) — 多 sheet 页 + 图表检测
// ---------------------------------------------------------------------------

interface SheetData {
  name: string;
  columns: string[];
  rows: string[][];
  rowCount: number;
  isChart: boolean;
}

function ExcelPreview({ url }: { url: string }) {
  const [sheets, setSheets] = useState<SheetData[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activeSheet, setActiveSheet] = useState(0);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const XLSX = await import("xlsx");
        const res = await fetch(url);
        const buf = await res.arrayBuffer();
        const wb = XLSX.read(buf, { type: "array" });

        if (!wb.SheetNames.length) throw new Error("No sheets found");

        const parsed: SheetData[] = wb.SheetNames.map((name) => {
          const ws = wb.Sheets[name]!;
          // 图表 sheet 检测：没有单元格引用但有 chart/drawing 标记
          const isChart = !ws["!ref"] && !!(ws["!chart"] || ws["!drawing"]);

          if (!ws["!ref"]) {
            return { name, columns: [], rows: [], rowCount: 0, isChart };
          }

          const json: string[][] = XLSX.utils.sheet_to_json(ws, { header: 1, defval: "" }) as string[][];
          const columns = (json[0] ?? []).map(String);
          const rows = json.slice(1).map((r) => r.map(String));

          return { name, columns, rows, rowCount: rows.length, isChart };
        });

        if (!cancelled) setSheets(parsed);
      } catch (e: unknown) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Failed to load");
      }
    }
    load();
    return () => { cancelled = true; };
  }, [url]);

  if (error) return <div className="p-4 text-sm text-red-500">{error}</div>;
  if (!sheets) return <div className="flex items-center justify-center p-8"><LoaderIcon className="size-5 animate-spin" /></div>;

  const current = sheets[activeSheet] ?? sheets[0];
  if (!current) return <div className="p-4 text-sm text-muted-foreground">No sheets found</div>;

  return (
    <div className="flex size-full flex-col">
      {/* Sheet tabs */}
      {sheets.length > 1 && (
        <div className="flex shrink-0 gap-0.5 overflow-x-auto border-b border-border bg-muted/50 px-2 py-1">
          {sheets.map((s, i) => (
            <button
              key={s.name}
              onClick={() => setActiveSheet(i)}
              className={cn(
                "shrink-0 rounded-md px-3 py-1 text-xs font-medium transition-colors",
                i === activeSheet
                  ? "bg-background text-foreground shadow-sm"
                  : "text-muted-foreground hover:text-foreground hover:bg-background/50",
              )}
            >
              {s.name}
              <span className="ml-1.5 text-[10px] text-muted-foreground">
                ({s.rowCount})
              </span>
            </button>
          ))}
        </div>
      )}

      {/* Sheet content */}
      <div className="flex-1 overflow-auto">
        {current.isChart ? (
          <ChartSheetPlaceholder name={current.name} />
        ) : current.columns.length === 0 ? (
          <div className="flex items-center justify-center p-8 text-sm text-muted-foreground">
            空 Sheet
          </div>
        ) : (
          <table className="w-full border-collapse text-xs">
            <thead>
              <tr>
                {current.columns.map((c, i) => (
                  <th
                    key={i}
                    className="sticky top-0 z-10 border-b border-border bg-muted px-3 py-2 text-left font-medium whitespace-nowrap"
                  >
                    {c}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {current.rows.map((row, ri) => (
                <tr key={ri} className="border-b border-border/50 hover:bg-muted/50">
                  {row.map((cell, ci) => (
                    <td key={ci} className="px-3 py-1.5 whitespace-nowrap">
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

function ChartSheetPlaceholder({ name }: { name: string }) {
  return (
    <div className="flex size-full flex-col items-center justify-center gap-3 text-muted-foreground">
      <svg className="size-12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
        <rect x="3" y="3" width="18" height="18" rx="2" />
        <path d="M7 17V13M12 17V9M17 17V5" strokeLinecap="round" />
      </svg>
      <p className="text-sm font-medium">「{name}」包含图表</p>
      <p className="text-xs">图表需要下载后用 Excel/WPS 查看</p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// DOCX Preview (mammoth)
// ---------------------------------------------------------------------------

function DocxPreview({ url }: { url: string }) {
  const [html, setHtml] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const mammoth = await import("mammoth");
        const res = await fetch(url);
        const buf = await res.arrayBuffer();
        const result = await mammoth.convertToHtml({ arrayBuffer: buf });
        if (!cancelled) setHtml(result.value);
      } catch (e:unknown) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Failed to load");
      }
    }
    load();
    return () => { cancelled = true; };
  }, [url]);

  if (error) return <div className="p-4 text-sm text-red-500">{error}</div>;
  if (!html) return <div className="flex items-center justify-center p-8"><LoaderIcon className="size-5 animate-spin" /></div>;

  return (
    <div
      className="size-full overflow-auto p-6 prose prose-sm dark:prose-invert max-w-none"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

// ---------------------------------------------------------------------------
// Image Preview
// ---------------------------------------------------------------------------

function ImagePreview({ url }: { url: string }) {
  return (
    <div className="flex size-full items-center justify-center overflow-auto bg-muted/30 p-4">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={url} alt="Preview" className="max-h-full max-w-full rounded shadow" />
    </div>
  );
}

// ---------------------------------------------------------------------------
// PDF Preview (native browser rendering)
// ---------------------------------------------------------------------------

function PDFPreview({ url }: { url: string }) {
  return <iframe className="size-full" src={url} title="PDF Preview" />;
}

// ---------------------------------------------------------------------------
// File type router
// ---------------------------------------------------------------------------

export type FilePreviewType = "excel" | "docx" | "image" | "pdf" | null;

export function getFilePreviewType(filepath: string): FilePreviewType {
  const ext = filepath.split(".").pop()?.toLowerCase() ?? "";
  if (["xlsx", "xls", "csv"].includes(ext)) return "excel";
  if (["doc", "docx"].includes(ext)) return "docx";
  if (["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico"].includes(ext)) return "image";
  if (ext === "pdf") return "pdf";
  return null;
}

interface FilePreviewProps {
  filepath: string;
  url: string;
  className?: string;
}

export function FilePreview({ filepath, url, className }: FilePreviewProps) {
  const type = getFilePreviewType(filepath);

  return (
    <div className={cn("size-full", className)}>
      {type === "excel" && <ExcelPreview url={url} />}
      {type === "docx" && <DocxPreview url={url} />}
      {type === "image" && <ImagePreview url={url} />}
      {type === "pdf" && <PDFPreview url={url} />}
      {!type && (
        <div className="flex size-full items-center justify-center text-sm text-muted-foreground">
          Preview not available for this file type
        </div>
      )}
    </div>
  );
}
