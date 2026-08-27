import { spawn } from "child_process";

const proc = spawn("/root/.nvm/versions/node/v24.12.0/bin/node", ["/home/collegeagent/canvas/mcp_server.js"]);

async function callTool(name, args, id) {
  return new Promise((resolve) => {
    const req = { jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } };
    let buf = "";
    const onData = (chunk) => {
      buf += chunk.toString();
      const lines = buf.split("\n");
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const resp = JSON.parse(line);
          if (resp.id === id) {
            proc.stdout.removeListener("data", onData);
            resolve(resp);
          }
        } catch (e) {}
      }
    };
    proc.stdout.on("data", onData);
    proc.stdin.write(JSON.stringify(req) + "\n");
  });
}

async function run() {
  const userId = "2420010e-ab11-40b5-b9df-be390b505dc5";
  const courseId = "1557905";

  console.log("1. Testing get_assignments (List Tier)");
  let res = await callTool("get_assignments", { userId, courseId }, 1);
  if (res.result.isError) console.error(res.result.content[0].text);
  else console.log("List length:", JSON.parse(res.result.content[0].text).length, "items");

  console.log("2. Testing get_assignment_detail (Anti-Hallucination Reject)");
  res = await callTool("get_assignment_detail", { userId, courseId, assignmentId: "99999999" }, 2);
  console.log("Rejection:", res.result.content[0].text);

  console.log("3. Testing get_syllabus (PDF parsing fallback on SOCIOL 1)");
  res = await callTool("get_syllabus", { userId, courseId }, 3);
  const sylData = JSON.parse(res.result.content[0].text);
  console.log("Syllabus sample:", sylData.syllabus_markdown.slice(0, 150));

  proc.kill();
  process.exit(0);
}

run();
