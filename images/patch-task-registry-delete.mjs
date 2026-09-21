import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const marker = "// Incremental run-ID removal: avoid rebuilding all retained tasks on each delete.";
const incrementalDelete = `${marker}
\tconst runId = current.runId?.trim();
\tif (runId) {
\t\tconst index = getTaskRegistryProcessState().taskIdsByRunId;
\t\tconst ids = index.get(runId);
\t\tif (ids) {
\t\t\tids.delete(taskId);
\t\t\tif (ids.size === 0) index.delete(runId);
\t\t}
\t}`;

export function patchTaskRegistryDelete(source) {
    const matches = [...source.matchAll(/function deleteTaskRecordById\(taskId\) \{[\s\S]*?\n\}/g)];
    if (matches.length !== 1) {
        throw new Error("Expected exactly one deleteTaskRecordById implementation; review upstream changes.");
    }
    const original = matches[0][0];
    if (original.includes(incrementalDelete)) return source;
    if (!source.includes(" as getTaskRegistryProcessState") ||
        !original.includes("const current = tasks.get(taskId);") ||
        !original.includes("if (!tryPersistTaskDelete(taskId)) return false;") ||
        !original.includes("taskDeliveryStates.delete(taskId);") ||
        !original.includes("emitTaskRegistryObserverEvent(") ||
        original.split("rebuildRunIdIndex();").length !== 2 ||
        original.indexOf("tryPersistTaskDelete(taskId)") > original.indexOf("rebuildRunIdIndex();")) {
        throw new Error("Task registry bundle does not match the supported hotfix shape; review upstream changes.");
    }
    return source.replace(original, original.replace("rebuildRunIdIndex();", incrementalDelete));
}

function hasNativeIncrementalDelete(source) {
    return source.includes("function deleteIndexedKey(") &&
        source.includes("function deleteRunIdIndex(") &&
        source.includes("function removeTaskIndexes(");
}

export function patchDist(dist) {
    const bundles = readdirSync(dist)
        .filter(name => /^task-registry-.*\.mjs$/.test(name))
        .map(name => ({ file: path.join(dist, name), source: readFileSync(path.join(dist, name), "utf8") }));
    const candidates = bundles.filter(({ source }) => source.includes("function deleteTaskRecordById(taskId) {"));
    if (bundles.some(({ source }) => hasNativeIncrementalDelete(source))) {
        console.log("Skipped task registry deletion hotfix: upstream provides native incremental index removal.");
        return;
    }
    if (candidates.length !== 1) {
        throw new Error(`Expected one task registry bundle in ${dist}; found ${candidates.length}.`);
    }
    const { file, source } = candidates[0];
    const patched = patchTaskRegistryDelete(source);
    if (patched !== source) writeFileSync(file, patched);
    console.log(`${patched === source ? "Already patched" : "Patched"} task registry deletion: ${file}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    if (!process.argv[2]) throw new Error("Usage: node patch-task-registry-delete.mjs <dist-directory>");
    patchDist(process.argv[2]);
}
