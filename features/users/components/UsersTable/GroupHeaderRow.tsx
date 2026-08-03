import { TableCell, TableRow } from "@/components/ui/table";

type Props = {
  title: string;
  count: number;
};

export function GroupHeaderRow({ title, count }: Props) {
  return (
    <TableRow className="bg-muted/40 hover:bg-muted/40">
      <TableCell colSpan={6} className="py-3 font-semibold">
        <div className="flex items-center justify-between">
          <span>{title}</span>

          <span className="text-sm text-muted-foreground">{count}</span>
        </div>
      </TableCell>
    </TableRow>
  );
}
