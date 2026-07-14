import { ApiError } from "./api-error";

export class UnauthorizedError extends ApiError {
  constructor(message = "Unauthorized") {
    super(message, 401);
  }
}

export class ForbiddenError extends ApiError {
  constructor(message = "Forbidden") {
    super(message, 403);
  }
}

export class NotFoundError extends ApiError {
  constructor(message = "Not found") {
    super(message, 404);
  }
}

export class ValidationError extends ApiError {
  constructor(message = "Validation error") {
    super(message, 400);
  }
}

export class ConflictError extends ApiError {
  constructor(message = "Conflict") {
    super(message, 409);
  }
}
