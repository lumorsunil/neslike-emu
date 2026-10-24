import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);

if (argv.length != 1) {
    console.error("Usage: node preprocessor.js <file.pp.*>");
    process.exit(1);
}

const raw = fs.readFileSync(argv[0], { encoding: "utf-8" });
const outFile = argv[0].replace(/\.pp\./, '.');

const require_cache = {};
const __dirname__ = path.resolve(".");

let __emitted_src = "";
const global = {
    emit(string) {
        __emitted_src += string;
    },
};

const regex = /\)§(.*?)\)§/gsm;
let match;

let out = "";
let cursor = 0;

while ((match = regex.exec(raw)) != null) {
    // console.error("found match: ", match[1]);

    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    await new AsyncFunction("global", `with (global) {${match[1]}}`)(global);

    out += raw.slice(cursor, match.index);
    out += __emitted_src;
    __emitted_src = "";
    cursor = match[0].length + match.index;
}

out += raw.slice(cursor);

console.log(out);
// console.log(outFile);
