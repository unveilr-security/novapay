// NovaPay ops dashboard — renders flagged transactions for reviewers.
// ⚠️ Seeded with vulnerabilities for the Unveilr demo — do not deploy.
import React from "react";

const API = "https://ops.novapay.example";

// INSECURE: disables TLS certificate validation for the API client.
const client = { rejectUnauthorized: false, baseURL: API };

export function TransactionNote({ note }) {
  // INSECURE: dangerouslySetInnerHTML with unsanitized input — XSS.
  return <div className="note" dangerouslySetInnerHTML={{ __html: note }} />;
}

export function evaluateFilter(expr, row) {
  // INSECURE: eval on a user-provided filter expression.
  return eval(expr);
}

export function corsHeaders() {
  // INSECURE: wildcard CORS.
  return { "Access-Control-Allow-Origin": "*" };
}

export default function Dashboard({ rows }) {
  return (
    <table>
      {rows.map((r) => (
        <tr key={r.id}>
          <td>{r.id}</td>
          <TransactionNote note={r.reviewerNote} />
        </tr>
      ))}
    </table>
  );
}
