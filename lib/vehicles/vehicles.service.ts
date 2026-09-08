import { sql } from "@/db";

import { hasPermission, PERMISSIONS } from "@/lib/auth/permissions";

import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type { CurrentUser } from "@/features/auth/types";

import type {
  Vehicle,
  CreateVehicleInput,
  UpdateVehicleInput,
} from "@/features/vehicles/types";

import { VEHICLE_TEXT } from "@/features/vehicles/constants/vehicle-text";

type VehicleRow = {
  id: string;
  name: string;
  type: string;
  capacity_weight: string | number;
  capacity_volume: string | number | null;
  cost_per_km: string | number;
  fixed_cost: string | number;
  available_from: string | null;
  available_to: string | null;
  is_active: boolean;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
};

function normalizeVehicle(row: VehicleRow): Vehicle {
  return {
    ...row,
    capacity_weight: Number(row.capacity_weight),
    capacity_volume:
      row.capacity_volume !== null ? Number(row.capacity_volume) : null,
    cost_per_km: Number(row.cost_per_km),
    fixed_cost: Number(row.fixed_cost),
  };
}

function validateAvailability(
  availableFrom: string | null,
  availableTo: string | null,
) {
  if (
    availableFrom &&
    availableTo &&
    new Date(availableTo) < new Date(availableFrom)
  ) {
    throw new ValidationError(VEHICLE_TEXT.error.invalid_availability);
  }
}

export class VehiclesService {
  static async getVehicles(currentUser: CurrentUser): Promise<Vehicle[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
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
    `) as VehicleRow[];

    return rows.map(normalizeVehicle);
  }

  static async getVehicle(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Vehicle> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_VIEW)) {
      throw new ForbiddenError();
    }

    const rows = (await sql`
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
    `) as VehicleRow[];

    if (!rows.length) {
      throw new NotFoundError(VEHICLE_TEXT.error.empty_vehicle);
    }

    return normalizeVehicle(rows[0]);
  }

  static async createVehicle(
    data: CreateVehicleInput,
    currentUser: CurrentUser,
  ): Promise<Vehicle> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_CREATE)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_create);
    }

    validateAvailability(
      data.available_from ?? null,
      data.available_to ?? null,
    );

    const vehicleId = crypto.randomUUID();

    const rows = (await sql`
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
    `) as VehicleRow[];

    return normalizeVehicle(rows[0]);
  }

  static async updateVehicle(
    id: string,
    data: UpdateVehicleInput,
    currentUser: CurrentUser,
  ): Promise<Vehicle> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_UPDATE)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_update);
    }

    const existing = await this.getVehicle(id, currentUser);

    const name = data.name !== undefined ? data.name : existing.name;

    const type = data.type !== undefined ? data.type : existing.type;

    const capacityWeight =
      data.capacity_weight !== undefined
        ? data.capacity_weight
        : existing.capacity_weight;

    const capacityVolume =
      data.capacity_volume !== undefined
        ? data.capacity_volume
        : existing.capacity_volume;

    const costPerKm =
      data.cost_per_km !== undefined ? data.cost_per_km : existing.cost_per_km;

    const fixedCost =
      data.fixed_cost !== undefined ? data.fixed_cost : existing.fixed_cost;

    const availableFrom =
      data.available_from !== undefined
        ? data.available_from
        : existing.available_from;

    const availableTo =
      data.available_to !== undefined
        ? data.available_to
        : existing.available_to;

    const isActive =
      data.is_active !== undefined ? data.is_active : existing.is_active;

    validateAvailability(availableFrom, availableTo);

    const rows = (await sql`
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
    `) as VehicleRow[];

    if (!rows.length) {
      throw new NotFoundError(VEHICLE_TEXT.error.empty_vehicle);
    }

    return normalizeVehicle(rows[0]);
  }
}
