import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";
import { patchTaskRegistryDelete } from "../images/patch-task-registry-delete.mjs";

const fixture = `import { Y as getTaskRegistryProcessState } from "./state.mjs";
function deleteTaskRecordById(taskId) {
\tensureTaskRegistryReady();
\tconst current = tasks.get(taskId);
\tif (!current) return false;
\tensureLinkedTaskFlowRegistryReady(current);
\tif (!tryPersistTaskDelete(taskId)) return false;
\tdeleteOwnerKeyIndex(taskId, current);
\tdeleteParentFlowIdIndex(taskId, current);
\tdeleteRelatedSessionKeyIndex(taskId, current);
\tclearTaskActivity(taskId);
\ttasks.delete(taskId);
\tbumpTaskRegistryRevision();
\ttaskDeliveryStates.delete(taskId);
\trebuildRunIdIndex();
\temitTaskRegistryObserverEvent(() => ({
\t\tkind: "deleted",
\t\ttaskId: current.taskId,
\t\tprevious: cloneTaskRecord(current)
\t}));
\treturn true;
}`;

// Optional real-image bundle ensures tests exercise the shipped function, not only the fixture.
const source = process.env.TASK_REGISTRY_BUNDLE
    ? readFileSync(process.env.TASK_REGISTRY_BUNDLE, "utf8")
    : fixture;

function setup(records, persist = true) {
    const tasks = new Map(records.map(record => [record.taskId, record]));
    const index = new Map();
    for (const record of records) {
        const key = record.runId?.trim();
        if (!key) continue;
        if (!index.has(key)) index.set(key, new Set());
        index.get(key).add(record.taskId);
    }
    const events = [];
    const deletions = [];
    const noop = () => {};
    const context = vm.createContext({
        tasks,
        taskDeliveryStates: new Map(),
        ensureTaskRegistryReady: noop,
        ensureLinkedTaskFlowRegistryReady: noop,
        tryPersistTaskDelete: () => persist,
        deleteOwnerKeyIndex: id => deletions.push(["owner", id]),
        deleteParentFlowIdIndex: id => deletions.push(["flow", id]),
        deleteRelatedSessionKeyIndex: id => deletions.push(["session", id]),
        clearTaskActivity: noop,
        bumpTaskRegistryRevision: noop,
        cloneTaskRecord: record => ({ ...record }),
        emitTaskRegistryObserverEvent: factory => events.push(factory()),
        getTaskRegistryProcessState: () => ({ taskIdsByRunId: index }),
        rebuildRunIdIndex: () => { throw new Error("Full index rebuild is forbidden"); },
    });
    const patched = patchTaskRegistryDelete(source);
    vm.runInContext(patched.match(/function deleteTaskRecordById\(taskId\) \{[\s\S]*?\n\}/)[0], context);
    return { tasks, index, events, deletions, remove: context.deleteTaskRecordById };
}

test("preserves other records sharing the trimmed run ID and removes empty buckets", () => {
    const state = setup([
        { taskId: "first", runId: " shared " },
        { taskId: "second", runId: "shared" },
    ]);
    assert.equal(state.remove("first"), true);
    assert.deepEqual([...state.index.get("shared")], ["second"]);
    assert.equal(state.events[0].previous.runId, " shared ");
    assert.deepEqual(state.deletions, [["owner", "first"], ["flow", "first"], ["session", "first"]]);
    assert.equal(state.remove("second"), true);
    assert.equal(state.index.size, 0);
});

test("does not mutate memory or notify observers when persistence fails", () => {
    const state = setup([{ taskId: "one", runId: "run" }], false);
    assert.equal(state.remove("one"), false);
    assert.equal(state.tasks.size, 1);
    assert.deepEqual([...state.index.get("run")], ["one"]);
    assert.equal(state.events.length, 0);
    assert.equal(state.deletions.length, 0);
});

test("supports missing tasks, missing run IDs and absent index buckets", () => {
    const state = setup([{ taskId: "one" }, { taskId: "two", runId: " " }, { taskId: "three", runId: "run" }]);
    state.index.clear();
    assert.equal(state.remove("missing"), false);
    for (const id of ["one", "two", "three"]) assert.equal(state.remove(id), true);
    assert.equal(state.index.size, 0);
});

test("deletes 125000 records without iterating the remaining task registry", () => {
    const count = 125000;
    const state = setup(Array.from({ length: count }, (_, i) => ({ taskId: `${i}`, runId: `run-${i}` })));
    for (const method of ["entries", "values", "keys", "forEach", Symbol.iterator]) {
        state.tasks[method] = () => { throw new Error("Registry-wide scan is forbidden"); };
    }
    for (let i = 0; i < count; i++) assert.equal(state.remove(`${i}`), true);
    assert.equal(state.tasks.size, 0);
    assert.equal(state.index.size, 0);
});

test("patch is idempotent and fails explicitly on incompatible upstream bundles", () => {
    const patched = patchTaskRegistryDelete(source);
    assert.equal(patchTaskRegistryDelete(patched), patched);
    assert.throws(() => patchTaskRegistryDelete(""), /exactly one/);
    assert.throws(() => patchTaskRegistryDelete(fixture.replace("rebuildRunIdIndex();", "changedUpstream();")), /supported hotfix shape/);
});
