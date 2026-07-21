import { NextResponse } from "next/server";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";

export async function GET() {
  try {
    const user = await requireUser();  
    return NextResponse.json(user);    
  } catch (error){return handleApiError(error)}
}