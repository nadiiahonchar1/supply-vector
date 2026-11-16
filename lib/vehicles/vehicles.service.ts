import { sql } from "@/db";

import { VEHICLE_TEXT } from "@/features/vehicles";
import type { CurrentUser } from "@/features/auth";
import { hasPermission, PERMISSIONS } from "@/lib/auth";
import { ForbiddenError, NotFoundError, ValidationError } from "@/lib/errors";

import type {
  Vehicle,
  CreateVehicleInput,
  UpdateVehicleInput,
} from "@/features/vehicles";

type VehicleRow = {
  id: string;
  name: string;
  type: string;
  capacity_weight: number;
  capacity_volume: number | null;
  cost_per_km: number;
  fixed_cost: number;
  available_from: string | null;
  available_to: string | null;
  is_active: boolean;
  created_by: string | null;
  updated_by: string | null;
  created_at: string;
  updated_at: string;
};

type TripCargoRow = {
  trip_id: string;
  total_weight: number | string;
  total_volume: number | string;
  missing_weights: number;
  missing_volumes: number;
};

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
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_view);
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
      WHERE is_active = TRUE
      ORDER BY name
    `) as VehicleRow[];

    return rows;
  }

  static async getVehicleById(
    id: string,
    currentUser: CurrentUser,
  ): Promise<Vehicle> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_VIEW)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_view);
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

    return rows[0];
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

    return rows[0];
  }

  static async updateVehicle(
    id: string,
    data: UpdateVehicleInput,
    currentUser: CurrentUser,
  ): Promise<Vehicle> {
    if (!hasPermission(currentUser.role, PERMISSIONS.VEHICLE_UPDATE)) {
      throw new ForbiddenError(VEHICLE_TEXT.error.forbidden_update);
    }

    const existing = await this.getVehicleById(id, currentUser);

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
    const capacityChanged =
      capacityWeight !== existing.capacity_weight ||
      capacityVolume !== existing.capacity_volume;

    if (capacityChanged) {
      const cargoRows = (await sql`
    WITH cargo AS (
      SELECT
        ti.trip_id,
        ti.quantity,
        p.weight_kg,
        p.volume_m3
      FROM trip_items ti
      JOIN trips t ON t.id = ti.trip_id
      JOIN shipments s ON s.id = ti.shipment_id
      JOIN shipment_items si ON si.shipment_id = s.id
      LEFT JOIN products p ON p.id = si.product_id
      WHERE t.vehicle_id = ${id}
        AND t.status IN ('planned', 'ready', 'in_transit')
        AND ti.shipment_id IS NOT NULL

      UNION ALL

      SELECT
        ti.trip_id,
        ti.quantity,
        p.weight_kg,
        p.volume_m3
      FROM trip_items ti
      JOIN trips t ON t.id = ti.trip_id
      JOIN transfer_requests tr
        ON tr.id = ti.transfer_request_id
      LEFT JOIN products p ON p.id = tr.product_id
      WHERE t.vehicle_id = ${id}
        AND t.status IN ('planned', 'ready', 'in_transit')
        AND ti.shipment_id IS NULL
        AND ti.transfer_request_id IS NOT NULL
    )
    SELECT
      trip_id,
      COALESCE(
        SUM(quantity * weight_kg),
        0
      ) AS total_weight,
      COALESCE(
        SUM(quantity * volume_m3),
        0
      ) AS total_volume,
      COUNT(*) FILTER (
        WHERE weight_kg IS NULL
      )::INTEGER AS missing_weights,
      COUNT(*) FILTER (
        WHERE ${capacityVolume} IS NOT NULL
          AND volume_m3 IS NULL
      )::INTEGER AS missing_volumes
    FROM cargo
    GROUP BY trip_id
  `) as TripCargoRow[];

      const exceedsCapacity = cargoRows.some((cargo) => {
        const totalWeight = Number(cargo.total_weight);
        const totalVolume = Number(cargo.total_volume);

        return (
          cargo.missing_weights > 0 ||
          cargo.missing_volumes > 0 ||
          totalWeight > capacityWeight ||
          (capacityVolume !== null && totalVolume > capacityVolume)
        );
      });

      if (exceedsCapacity) {
        throw new ValidationError(
          VEHICLE_TEXT.error.capacity_below_current_load,
        );
      }
    }
    if (existing.is_active && !isActive) {
      const activeTripRows = await sql`
      SELECT id
      FROM trips
      WHERE vehicle_id = ${id}
        AND status IN ('ready', 'in_transit')
      LIMIT 1
    `;

      if (activeTripRows.length) {
        throw new ValidationError(VEHICLE_TEXT.error.vehicle_has_active_trip);
      }
    }

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

    return rows[0];
  }
}
