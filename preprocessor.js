import fs from "node:fs";

const argv = process.argv.slice(2);

if (argv.length != 1) {
    console.error("Usage: node preprocessor.js <file.pp.*>");
    process.exit(1);
}

const raw = fs.readFileSync(argv[0], { encoding: "utf-8" });
const outFile = argv[0].replace(/\.pp\./, '.');

const global = {
    require: (file_path) => {
        const code = fs.readFileSync(file_path, { encoding: "utf-8" });
        return new Function("global", code)(global);
    },
};

const regex = /\)§(.*?)\)§/gsm;
let match;

let out = "";
let cursor = 0;

while ((match = regex.exec(raw)) != null) {
    // console.error("found match: ", match[1]);

    let result = new Function("global", match[1])(global);
    if (typeof result === "undefined") {
        result = "";
    }
    if (typeof result !== "string") {
        throw new Error("preprocessor result must be a string, found " + typeof result);
    }

    out += raw.slice(cursor, match.index);
    out += result;
    cursor = match[0].length + match.index;
}

out += raw.slice(cursor);

console.log(out);
// console.log(outFile);
