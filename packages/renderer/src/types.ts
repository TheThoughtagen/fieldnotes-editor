export type JsonSchema = Record<string, unknown>;

export type SourcePosition = {
  line: number;
  column: number;
};

export type RenderDiagnostic = {
  code: string;
  message: string;
  severity: "warning" | "error";
  position?: SourcePosition;
};

export type FrontmatterResult = {
  source: string;
  body: string;
  data: Record<string, unknown>;
  range?: { from: number; to: number };
  diagnostics: RenderDiagnostic[];
};
