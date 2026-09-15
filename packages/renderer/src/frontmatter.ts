import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import type { ErrorObject } from "ajv";
import { parseDocument } from "yaml";
import type { FrontmatterResult, JsonSchema, RenderDiagnostic } from "./types.js";

const ajv = new Ajv2020();

addFormats(ajv);

export function extractFrontmatter(source: string): FrontmatterResult {
  const openingMatch = /^(?:\uFEFF)?---[\t ]*(?:\r?\n|$)/.exec(source);

  if (openingMatch === null) {
    return diagnosticResult(source, source, "frontmatter.missing", "Frontmatter must begin with a YAML delimiter.");
  }

  const closingExpression = /^---[\t ]*(?:\r?\n|$)/gm;
  closingExpression.lastIndex = openingMatch[0].length;
  const closingMatch = closingExpression.exec(source);

  if (closingMatch === null) {
    return diagnosticResult(source, "", "frontmatter.unclosed", "Frontmatter is missing its closing YAML delimiter.");
  }

  const yamlSource = source.slice(openingMatch[0].length, closingMatch.index);
  const range = { from: 0, to: closingMatch.index + closingMatch[0].length };
  const body = source.slice(range.to);

  try {
    const document = parseDocument(yamlSource, { schema: "core", version: "1.2" });

    if (document.errors.length > 0) {
      return diagnosticResult(source, body, "frontmatter.invalid", document.errors[0]?.message ?? "Invalid YAML frontmatter.", range);
    }

    const data = document.toJS();

    if (!isRecord(data)) {
      return diagnosticResult(source, body, "frontmatter.nonObject", "Frontmatter must be a YAML object.", range);
    }

    return { source, body, data, range, diagnostics: [] };
  } catch (error) {
    return diagnosticResult(
      source,
      body,
      "frontmatter.invalid",
      error instanceof Error ? error.message : "Invalid YAML frontmatter.",
      range
    );
  }
}

export function validateFrontmatter(value: Record<string, unknown>, schema: JsonSchema): RenderDiagnostic[] {
  const validate = ajv.compile(schema);

  return validate(value) ? [] : (validate.errors ?? []).map(errorToDiagnostic);
}

function diagnosticResult(
  source: string,
  body: string,
  code: string,
  message: string,
  range?: { from: number; to: number }
): FrontmatterResult {
  return {
    source,
    body,
    data: {},
    ...(range === undefined ? {} : { range }),
    diagnostics: [{ code, message, severity: "error", position: { line: 1, column: 1 } }]
  };
}

function errorToDiagnostic(error: ErrorObject): RenderDiagnostic {
  return {
    code: `schema.${error.keyword}`,
    message: `${error.instancePath || "/"} ${error.message ?? "is invalid"}`,
    severity: "error"
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
