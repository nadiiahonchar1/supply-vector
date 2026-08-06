"use client";

import { useState } from "react";
import { useLogin } from "../api/hooks";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { loginSchema, type LoginFormData } from "../validation/login.schema";
import {
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Input,
  Label,
} from "@/components/ui";
import { AUTH_TEXT } from "../constants/auth-text";

export function LoginForm() {
  const { login } = useLogin();

  const [serverError, setServerError] = useState("");

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginFormData>({
    resolver: zodResolver(loginSchema),
    defaultValues: {
      email: "",
      password: "",
    },
  });

  async function onSubmit(values: LoginFormData) {
    try {
      setServerError("");
      await login(values);
    } catch {
      setServerError(AUTH_TEXT.error.invalid);
    }
  }

  return (
    <Card className="mx-auto w-full max-w-md">
      <CardHeader>
        <CardTitle>{AUTH_TEXT.dialog.title}</CardTitle>

        <CardDescription>{AUTH_TEXT.dialog.description}</CardDescription>
      </CardHeader>

      <CardContent>
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-5">
          <div className="space-y-2">
            <Label htmlFor="email">{AUTH_TEXT.dialog.email}</Label>

            <Input
              id="email"
              type="email"
              placeholder="admin@test.com"
              autoComplete="email"
              {...register("email")}
            />

            {errors.email && (
              <p className="text-sm text-destructive">{errors.email.message}</p>
            )}
          </div>

          <div className="space-y-2">
            <Label htmlFor="password">{AUTH_TEXT.dialog.password}</Label>

            <Input
              id="password"
              type="password"
              autoComplete="current-password"
              {...register("password")}
            />

            {errors.password && (
              <p className="text-sm text-destructive">
                {errors.password.message}
              </p>
            )}
          </div>

          {serverError && (
            <p className="text-sm text-destructive">{serverError}</p>
          )}

          <Button type="submit" className="w-full" disabled={isSubmitting}>
            {isSubmitting
              ? AUTH_TEXT.dialog.submitting
              : AUTH_TEXT.dialog.submit}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
