import { NextResponse } from "next/server";

import { getCurrentUser } from "@/lib/auth/get-current-user";
import { sql } from "@/db";

export async function GET() {
  const user = await getCurrentUser();

  if (!user) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 });
  }

  return NextResponse.json(user);
}

export async function PATCH(req: Request) {
  const currentUser = await getCurrentUser();

  if (!currentUser) {
    return NextResponse.json({ message: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json();

  const { first_name, last_name } = body;

  const result = await sql`
    UPDATE users
    SET
      first_name = ${first_name},
      last_name = ${last_name}
    WHERE id = ${currentUser.id}
    RETURNING
      id,
      email,
      first_name,
      last_name,
      is_active
  `;

  return NextResponse.json(result[0]);
}
