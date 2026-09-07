import { sql } from "@/db";

import { getCurrentUser } from "@/lib/auth/get-current-user";
import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type {
  Vehicle,
  CreateVehicleInput,
  UpdateVehicleInput,
} from "@/features/vehicles/types";

import { VEHICLE_TEXT } from "@/features/vehicles/constants/vehicle-text";

export class VehiclesService {
  private static async requireCurrentUser() {
    const currentUser = await getCurrentUser();

    if (!currentUser) {
      throw new ForbiddenError();
    }

    return currentUser;
  }

  static async getVehicles(): Promise<Vehicle[]> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_VIEW)) {
      throw new ForbiddenError();
    }

    return (await sql`
      SELECT
        id,
        name,
        type,
        capacity_weight,
        capacity_volume,
        cost_per_km,
        fixed_cost,
        available_from,
        available_to,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM vehicles
      ORDER BY name
    `) as Vehicle[];
  }

  static async getVehicle(id: string): Promise<Vehicle> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_VIEW)) {
      throw new ForbiddenError();
    }

    const vehicles = (await sql`
      SELECT
        id,
        name,
        type,
        capacity_weight,
        capacity_volume,
        cost_per_km,
        fixed_cost,
        available_from,
        available_to,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
      FROM vehicles
      WHERE id = ${id}
      LIMIT 1
    `) as Vehicle[];

    if (!vehicles.length) {
      throw new NotFoundError(VEHICLE_TEXT.error.empty_vehicle);
    }

    return vehicles[0];
  }

  static async createVehicle(data: CreateVehicleInput): Promise<Vehicle> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_CREATE)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_create);
    }

    if (
      data.available_from &&
      data.available_to &&
      new Date(data.available_to) < new Date(data.available_from)
    ) {
      throw new ValidationError(VEHICLE_TEXT.error.invalid_availability);
    }

    const vehicleId = crypto.randomUUID();

    const vehicles = (await sql`
      INSERT INTO vehicles (
        id,
        name,
        type,
        capacity_weight,
        capacity_volume,
        cost_per_km,
        fixed_cost,
        available_from,
        available_to,
        is_active,
        created_by,
        updated_by
      )
      VALUES (
        ${vehicleId},
        ${data.name},
        ${data.type},
        ${data.capacity_weight},
        ${data.capacity_volume ?? null},
        ${data.cost_per_km},
        ${data.fixed_cost},
        ${data.available_from ?? null},
        ${data.available_to ?? null},
        TRUE,
        ${currentUser.id},
        ${currentUser.id}
      )
      RETURNING
        id,
        name,
        type,
        capacity_weight,
        capacity_volume,
        cost_per_km,
        fixed_cost,
        available_from,
        available_to,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as Vehicle[];

    return vehicles[0];
  }

  static async updateVehicle(
    id: string,
    data: UpdateVehicleInput,
  ): Promise<Vehicle> {
    const currentUser = await this.requireCurrentUser();

    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_UPDATE)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_update);
    }

    const existingVehicle = await this.getVehicle(id);

    const availableFrom =
      data.available_from !== undefined
        ? data.available_from
        : existingVehicle.available_from;

    const availableTo =
      data.available_to !== undefined
        ? data.available_to
        : existingVehicle.available_to;

    if (
      availableFrom &&
      availableTo &&
      new Date(availableTo) < new Date(availableFrom)
    ) {
      throw new ValidationError(VEHICLE_TEXT.error.invalid_availability);
    }

    const name = data.name !== undefined ? data.name : existingVehicle.name;

    const type = data.type !== undefined ? data.type : existingVehicle.type;

    const capacityWeight =
      data.capacity_weight !== undefined
        ? data.capacity_weight
        : existingVehicle.capacity_weight;

    const capacityVolume =
      data.capacity_volume !== undefined
        ? data.capacity_volume
        : existingVehicle.capacity_volume;

    const costPerKm =
      data.cost_per_km !== undefined
        ? data.cost_per_km
        : existingVehicle.cost_per_km;

    const fixedCost =
      data.fixed_cost !== undefined
        ? data.fixed_cost
        : existingVehicle.fixed_cost;

    const isActive =
      data.is_active !== undefined ? data.is_active : existingVehicle.is_active;

    const vehicles = (await sql`
      UPDATE vehicles
      SET
        name = ${name},
        type = ${type},
        capacity_weight = ${capacityWeight},
        capacity_volume = ${capacityVolume},
        cost_per_km = ${costPerKm},
        fixed_cost = ${fixedCost},
        available_from = ${availableFrom},
        available_to = ${availableTo},
        is_active = ${isActive},
        updated_by = ${currentUser.id},
        updated_at = NOW()
      WHERE id = ${id}
      RETURNING
        id,
        name,
        type,
        capacity_weight,
        capacity_volume,
        cost_per_km,
        fixed_cost,
        available_from,
        available_to,
        is_active,
        created_by,
        updated_by,
        created_at,
        updated_at
    `) as Vehicle[];

    if (!vehicles.length) {
      throw new NotFoundError(VEHICLE_TEXT.error.empty_vehicle);
    }

    return vehicles[0];
  }
}
