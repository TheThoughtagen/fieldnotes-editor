import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import rehypeHighlight from "rehype-highlight";
import rehypeKatex from "rehype-katex";
import rehypeRaw from "rehype-raw";
import rehypeSanitize from "rehype-sanitize";
import { unified } from "unified";
import { extractFrontmatter, validateFrontmatter } from "./frontmatter.js";
import { discoverImageAssets } from "./assets.js";
import { assignHeadingIdsAndBuildToc } from "./headings.js";
import { deriveTextMetrics } from "./metrics.js";
import { serializeNormalizedHtml } from "./normalize.js";
import { prepareCodeHighlightRanges, transformAdvancedHtml } from "./plugins/advanced.js";
import {
  collectTrustedMarkup,
  enforceIframePolicy,
  restoreTrustedMarkup,
  sanitizeSchema
} from "./sanitize.js";
import type { RenderOptions, RenderedDocument } from "./types.js";

export async function renderDocument(source: string, options: RenderOptions = {}): Promise<RenderedDocument> {
  const frontmatter = extractFrontmatter(source);
  const diagnostics = [
    ...frontmatter.diagnostics,
    ...(options.frontmatterSchema === undefined
      ? []
      : validateFrontmatter(frontmatter.data, options.frontmatterSchema))
  ];
  const wordsPerMinute = options.wordsPerMinute;
  const validWordsPerMinute = wordsPerMinute === undefined
    || (Number.isFinite(wordsPerMinute) && wordsPerMinute > 0);
  if (!validWordsPerMinute) {
    diagnostics.push({
      code: "options.words-per-minute",
      message: "wordsPerMinute must be a finite positive number; using 220.",
      severity: "warning"
    });
  }

  const parser = unified().use(remarkParse).use(remarkGfm).use(remarkMath);
  const tree = parser.parse(frontmatter.body);
  const toc = assignHeadingIdsAndBuildToc(tree, diagnostics);
  const metrics = deriveTextMetrics(tree, validWordsPerMinute ? (wordsPerMinute ?? 220) : 220);
  const assetDiscovery = discoverImageAssets(tree, options);
  diagnostics.push(...assetDiscovery.diagnostics);
  prepareCodeHighlightRanges(tree, diagnostics);
  const trustedMarkup = collectTrustedMarkup(tree);
  const transformed = await unified()
    .use(remarkRehype, { allowDangerousHtml: true })
    .use(rehypeRaw)
    .use(() => tree => enforceIframePolicy(tree, diagnostics))
    .use(rehypeSanitize, sanitizeSchema)
    .use(() => tree => restoreTrustedMarkup(tree, trustedMarkup))
    .use(rehypeKatex)
    .use(rehypeHighlight, { plainText: ["mermaid"] })
    .use(() => transformAdvancedHtml)
    .run(tree);
  const html = serializeNormalizedHtml(transformed);

  return {
    html,
    normalizedHtml: html,
    toc,
    frontmatter: frontmatter.data,
    diagnostics,
    assets: assetDiscovery.assets,
    ...metrics
  };
}
