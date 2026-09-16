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

export type Heading = {
  depth: 2 | 3;
  id: string;
  text: string;
  children: Heading[];
};

export type AssetReference = {
  kind: "image";
  source: string;
  resolvedPath?: string;
  remote: boolean;
  alt: string;
  title?: string;
};

export type RenderOptions = {
  sourcePath?: string;
  baseUrl?: string;
  allowRemoteImages?: boolean;
  frontmatterSchema?: JsonSchema;
  validateFrontmatter?: (value: Record<string, unknown>, schema: JsonSchema) => RenderDiagnostic[] | Promise<RenderDiagnostic[]>;
  codeTheme?: string;
  wordsPerMinute?: number;
};

export type RenderedDocument = {
  html: string;
  normalizedHtml: string;
  toc: Heading[];
  frontmatter: Record<string, unknown>;
  diagnostics: RenderDiagnostic[];
  assets: AssetReference[];
  plainText: string;
  wordCount: number;
  readingMinutes: number;
};
