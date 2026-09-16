import { expect, test } from "vitest";
import { posix } from "../src/browser-path.js";

test("relative parent segments survive normalization while absolute paths stay rooted", () => {
  expect(posix.join(".", "../assets/a.png")).toBe("../assets/a.png");
  expect(posix.normalize("../../assets/a.png")).toBe("../../assets/a.png");
  expect(posix.join("notes", "../assets/a.png")).toBe("assets/a.png");
  expect(posix.normalize("/../../assets/a.png")).toBe("/assets/a.png");
});
