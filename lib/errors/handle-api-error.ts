import { NextResponse } from "next/server";

import { ApiError } from "@/lib/errors";
import { TRIP_ITEM_TEXT } from "@/features/trips";

export function handleApiError(error: unknown) {
  if (
    error instanceof Error &&
    error.message.includes("TRIP_CAPACITY_EXCEEDED")
  ) {
    return NextResponse.json(
      {
        message: TRIP_ITEM_TEXT.error.capacity_exceeded,
      },
      {
        status: 400,
      },
    );
  }

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
