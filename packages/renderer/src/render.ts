import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import rehypeStringify from "rehype-stringify";
import { unified } from "unified";
import { extractFrontmatter, validateFrontmatter } from "./frontmatter.js";
import { assignHeadingIdsAndBuildToc } from "./headings.js";
import type { RenderOptions, RenderedDocument } from "./types.js";

export async function renderDocument(source: string, options: RenderOptions = {}): Promise<RenderedDocument> {
  const frontmatter = extractFrontmatter(source);
  const diagnostics = [
    ...frontmatter.diagnostics,
    ...(options.frontmatterSchema === undefined
      ? []
      : validateFrontmatter(frontmatter.data, options.frontmatterSchema))
  ];
  const parser = unified().use(remarkParse).use(remarkGfm);
  const tree = parser.parse(frontmatter.body);
  const toc = assignHeadingIdsAndBuildToc(tree);
  const transformed = await unified().use(remarkRehype).run(tree);
  const html = String(unified().use(rehypeStringify).stringify(transformed));

  return {
    html,
    normalizedHtml: html,
    toc,
    frontmatter: frontmatter.data,
    diagnostics,
    assets: [],
    plainText: "",
    wordCount: 0,
    readingMinutes: 1
  };
}
