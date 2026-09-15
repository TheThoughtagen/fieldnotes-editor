import { generatedCases } from "./conformance.generated.js";
import type { RenderedDocument, RenderOptions } from "./types.js";

type DeepReadonly<T> = T extends (...args: never[]) => unknown
  ? T
  : T extends readonly (infer Item)[]
    ? readonly DeepReadonly<Item>[]
    : T extends object
      ? { readonly [Key in keyof T]: DeepReadonly<T[Key]> }
      : T;

export type ConformanceCase = {
  readonly name: string;
  readonly source: string;
  readonly options?: RenderOptions;
  readonly expected: {
    readonly renderer: DeepReadonly<RenderedDocument>;
    readonly hydratedDom: string;
  };
};

export const conformanceCases: readonly ConformanceCase[] = generatedCases;
