import { describe, expect, it } from "vitest";
import { renderDocument } from "../src/index.js";

describe("inert Mermaid output", () => {
  it("emits escaped canonical source with a deterministic SHA-256 digest", async () => {
    const source = "graph TD; A--><script>alert(1)</script>B\r\n";
    const result = await renderDocument(`\`\`\`mermaid\r\n${source}\`\`\`\r\n`);

    expect(result.html).toMatch(
      /^<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:[a-f0-9]{64}">/u
    );
    expect(result.html).toContain("graph TD; A-->&#x3C;script>alert(1)&#x3C;/script>B");
    expect(result.html).not.toContain("<svg");
    expect(result.html).not.toContain("<script>");
    expect(await renderDocument(`\`\`\`mermaid\n${source.replace(/\r\n?/gu, "\n")}\`\`\`\n`))
      .toMatchObject({ html: result.html });
  });

  it("hashes exact LF-normalized source bytes without a trailing newline", async () => {
    const result = await renderDocument("```mermaid\ngraph TD; A-->B\n```\n");

    expect(result.html).toContain(
      'data-fieldnotes-mermaid="sha256:c18237e0a535bdb73d9c241d24e7905bd72b7e64ca3ece4b5c241eb4fd8c7546"'
    );
    expect(result.html).toContain(">graph TD; A-->B</pre>");
  });
});
