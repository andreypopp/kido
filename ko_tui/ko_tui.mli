module Launch = Launch
module Api = Api

val run : dir:string -> executable:string -> pager:string -> (unit, string) result
