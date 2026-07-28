import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const AjvConstructor = Ajv2020 as unknown as new (options: { strict: boolean }) => {
    compile: (schema: unknown) => ((value: unknown) => boolean) & { errors?: unknown };
};
const applyFormats = addFormats as unknown as (ajv: InstanceType<typeof AjvConstructor>) => void;

const protocolRoot = path.resolve("../../protocol");

describe("Protocol fixtures", () => {
    for (const name of ["envelope", "plan"]) {
        it(`validates the ${name} example`, () => {
            const ajv = new AjvConstructor({ strict: true });
            applyFormats(ajv);
            const schema = JSON.parse(
                fs.readFileSync(path.join(protocolRoot, "schemas", `${name}.schema.json`), "utf8")
            );
            const exampleName = name === "envelope" ? "session-ready" : name;
            const example = JSON.parse(
                fs.readFileSync(path.join(protocolRoot, "examples", `${exampleName}.json`), "utf8")
            );
            const validate = ajv.compile(schema);
            assert.equal(validate(example), true, JSON.stringify(validate.errors));
        });
    }
});
