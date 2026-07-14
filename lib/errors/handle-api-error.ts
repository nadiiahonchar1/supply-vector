import { NextResponse } from "next/server";

import { ApiError } from "./api-error";

export function handleApiError(error: unknown) {
  if (error instanceof ApiError) {
    return NextResponse.json(
      {
        message: error.message,
      },
      {
        status: error.status,
      },
    );
  }

  console.error(error);

  return NextResponse.json(
    {
      message: "Internal server error",
    },
    {
      status: 500,
    },
  );
}
