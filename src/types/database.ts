
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "alert_events": {
                  Row: {
                    "id": string,"kind": string,"org_id": string,"plant_id": string,"recipients": (string)[],"sent_at": string,"shift_instance_id": string | null,"subject_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: string,"kind": string,"org_id": string,"plant_id": string,"recipients": (string)[],"sent_at"?: string,"shift_instance_id"?: string | null,"subject_id"?: string | null
                  }
                  Update: {
                    "id"?: string,"kind"?: string,"org_id"?: string,"plant_id"?: string,"recipients"?: (string)[],"sent_at"?: string,"shift_instance_id"?: string | null,"subject_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "alert_events_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "alert_events_shift_instance_id_plant_id_fkey"
      columns: ["shift_instance_id","plant_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"app_events": {
                  Row: {
                    "at": string,"device_id": string | null,"id": number,"name": string,"org_id": string,"plant_id": string | null,"props": NonNullable<Json>,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "at"?: string,"device_id"?: string | null,"id"?: never,"name": string,"org_id": string,"plant_id"?: string | null,"props"?: NonNullable<Json>,"user_id"?: string | null
                  }
                  Update: {
                    "at"?: string,"device_id"?: string | null,"id"?: never,"name"?: string,"org_id"?: string,"plant_id"?: string | null,"props"?: NonNullable<Json>,"user_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "app_events_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "app_events_org_id_fkey"
      columns: ["org_id"]
isOneToOne: false
      referencedRelation: "organizations"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "app_events_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"areas": {
                  Row: {
                    "active": boolean,"created_at": string,"id": string,"kind": "washroom"|"finishing"|"folding"|"packing"|"other","name": string,"org_id": string,"plant_id": string,"sort_order": number
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"kind": "washroom"|"finishing"|"folding"|"packing"|"other","name": string,"org_id": string,"plant_id": string,"sort_order"?: number
                  }
                  Update: {
                    "active"?: boolean,"created_at"?: string,"id"?: string,"kind"?: "washroom"|"finishing"|"folding"|"packing"|"other","name"?: string,"org_id"?: string,"plant_id"?: string,"sort_order"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "areas_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"audit_log": {
                  Row: {
                    "action": string,"actor_device_id": string | null,"actor_user_id": string | null,"after": Json | null,"at": string,"before": Json | null,"entity": string,"entity_id": string | null,"id": number,"org_id": string,"plant_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"actor_device_id"?: string | null,"actor_user_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"entity": string,"entity_id"?: string | null,"id"?: never,"org_id": string,"plant_id"?: string | null
                  }
                  Update: {
                    "action"?: string,"actor_device_id"?: string | null,"actor_user_id"?: string | null,"after"?: Json | null,"at"?: string,"before"?: Json | null,"entity"?: string,"entity_id"?: string | null,"id"?: never,"org_id"?: string,"plant_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "audit_log_actor_device_id_fkey"
      columns: ["actor_device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "audit_log_org_id_fkey"
      columns: ["org_id"]
isOneToOne: false
      referencedRelation: "organizations"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "audit_log_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"devices": {
                  Row: {
                    "app_version": string | null,"area_id": string,"display_languages": (string)[],"id": string,"last_seen_at": string | null,"name": string,"org_id": string,"paired_at": string,"plant_id": string,"revoked_at": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "app_version"?: string | null,"area_id": string,"display_languages"?: (string)[],"id"?: string,"last_seen_at"?: string | null,"name": string,"org_id": string,"paired_at"?: string,"plant_id": string,"revoked_at"?: string | null,"user_id": string
                  }
                  Update: {
                    "app_version"?: string | null,"area_id"?: string,"display_languages"?: (string)[],"id"?: string,"last_seen_at"?: string | null,"name"?: string,"org_id"?: string,"paired_at"?: string,"plant_id"?: string,"revoked_at"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "devices_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "devices_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"display_messages": {
                  Row: {
                    "area_id": string | null,"body": string,"body_i18n": NonNullable<Json>,"body_lang": string,"created_at": string,"created_by": string,"expires_at": string,"id": string,"org_id": string,"plant_id": string,"retracted_at": string | null,"severity": "info"|"urgent","starts_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id"?: string | null,"body": string,"body_i18n"?: NonNullable<Json>,"body_lang": string,"created_at"?: string,"created_by": string,"expires_at": string,"id"?: string,"org_id": string,"plant_id": string,"retracted_at"?: string | null,"severity"?: "info"|"urgent","starts_at"?: string
                  }
                  Update: {
                    "area_id"?: string | null,"body"?: string,"body_i18n"?: NonNullable<Json>,"body_lang"?: string,"created_at"?: string,"created_by"?: string,"expires_at"?: string,"id"?: string,"org_id"?: string,"plant_id"?: string,"retracted_at"?: string | null,"severity"?: "info"|"urgent","starts_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "display_messages_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "display_messages_body_lang_fkey"
      columns: ["body_lang"]
isOneToOne: false
      referencedRelation: "languages"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "display_messages_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"entry_staff": {
                  Row: {
                    "active": boolean,"created_at": string,"display_name": string,"failed_pin_attempts": number,"has_pin": boolean | null,"home_shift_id": string | null,"id": string,"language": string,"locked_until": string | null,"org_id": string,"pin_hash": string | null,"plant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"created_at"?: string,"display_name": string,"failed_pin_attempts"?: number,"has_pin"?: never,"home_shift_id"?: string | null,"id"?: string,"language"?: string,"locked_until"?: string | null,"org_id": string,"pin_hash"?: string | null,"plant_id": string,"updated_at"?: string
                  }
                  Update: {
                    "active"?: boolean,"created_at"?: string,"display_name"?: string,"failed_pin_attempts"?: number,"has_pin"?: never,"home_shift_id"?: string | null,"id"?: string,"language"?: string,"locked_until"?: string | null,"org_id"?: string,"pin_hash"?: string | null,"plant_id"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "entry_staff_home_shift_id_plant_id_fkey"
      columns: ["home_shift_id","plant_id"]
isOneToOne: false
      referencedRelation: "shifts"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "entry_staff_language_fkey"
      columns: ["language"]
isOneToOne: false
      referencedRelation: "languages"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "entry_staff_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"finished_goods_entries": {
                  Row: {
                    "area_id": string,"client_id": string,"created_at": string,"entered_by": string,"id": string,"item_type_id": string,"loose_pieces": number,"note": string | null,"occurred_at": string,"org_id": string,"pack_size_used": number | null,"packs": number,"pieces": number | null,"plant_id": string,"queue_item_id": string | null,"shift_instance_id": string | null,"source": "manual"|"queue_completion","staff_id": string | null,"station_id": string | null,"void_reason": string | null,"voided_at": string | null,"voided_by": string | null,"wash_group_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"client_id": string,"created_at"?: string,"entered_by": string,"id"?: string,"item_type_id": string,"loose_pieces"?: number,"note"?: string | null,"occurred_at"?: string,"org_id": string,"pack_size_used"?: number | null,"packs"?: number,"pieces"?: never,"plant_id": string,"queue_item_id"?: string | null,"shift_instance_id"?: string | null,"source"?: "manual"|"queue_completion","staff_id"?: string | null,"station_id"?: string | null,"void_reason"?: string | null,"voided_at"?: string | null,"voided_by"?: string | null,"wash_group_id": string
                  }
                  Update: {
                    "area_id"?: string,"client_id"?: string,"created_at"?: string,"entered_by"?: string,"id"?: string,"item_type_id"?: string,"loose_pieces"?: number,"note"?: string | null,"occurred_at"?: string,"org_id"?: string,"pack_size_used"?: number | null,"packs"?: number,"pieces"?: never,"plant_id"?: string,"queue_item_id"?: string | null,"shift_instance_id"?: string | null,"source"?: "manual"|"queue_completion","staff_id"?: string | null,"station_id"?: string | null,"void_reason"?: string | null,"voided_at"?: string | null,"voided_by"?: string | null,"wash_group_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "finished_goods_entries_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_item_type_id_plant_id_fkey"
      columns: ["item_type_id","plant_id"]
isOneToOne: false
      referencedRelation: "item_types"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "finished_goods_entries_queue_item_id_plant_id_fkey"
      columns: ["queue_item_id","plant_id"]
isOneToOne: false
      referencedRelation: "queue_board"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_queue_item_id_plant_id_fkey"
      columns: ["queue_item_id","plant_id"]
isOneToOne: false
      referencedRelation: "queue_items"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_shift_instance_id_area_id_fkey"
      columns: ["shift_instance_id","area_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "finished_goods_entries_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_station_id_plant_id_fkey"
      columns: ["station_id","plant_id"]
isOneToOne: false
      referencedRelation: "stations"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"import_batches": {
                  Row: {
                    "created_at": string,"created_by": string | null,"errors": NonNullable<Json>,"file_sha256": string | null,"id": string,"org_id": string,"plant_id": string,"rows_inserted": number,"rows_skipped": number,"rows_total": number,"source": "manual"|"accuflow_csv"|"accuflow_api","status": string,"storage_path": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"errors"?: NonNullable<Json>,"file_sha256"?: string | null,"id"?: string,"org_id": string,"plant_id": string,"rows_inserted"?: number,"rows_skipped"?: number,"rows_total"?: number,"source": "manual"|"accuflow_csv"|"accuflow_api","status"?: string,"storage_path"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"errors"?: NonNullable<Json>,"file_sha256"?: string | null,"id"?: string,"org_id"?: string,"plant_id"?: string,"rows_inserted"?: number,"rows_skipped"?: number,"rows_total"?: number,"source"?: "manual"|"accuflow_csv"|"accuflow_api","status"?: string,"storage_path"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "import_batches_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"item_types": {
                  Row: {
                    "active": boolean,"category": "mat"|"linen"|"apparel"|"towel"|"mop"|"other","color_hex": string,"count_mode": "unit"|"pack","created_at": string,"id": string,"name": string,"name_i18n": NonNullable<Json>,"org_id": string,"pack_size": number | null,"pieces_per_load": number | null,"pieces_per_load_source": string | null,"plant_id": string,"sort_order": number,"updated_at": string,"wash_group_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"category": "mat"|"linen"|"apparel"|"towel"|"mop"|"other","color_hex"?: string,"count_mode"?: "unit"|"pack","created_at"?: string,"id"?: string,"name": string,"name_i18n"?: NonNullable<Json>,"org_id": string,"pack_size"?: number | null,"pieces_per_load"?: number | null,"pieces_per_load_source"?: string | null,"plant_id": string,"sort_order"?: number,"updated_at"?: string,"wash_group_id": string
                  }
                  Update: {
                    "active"?: boolean,"category"?: "mat"|"linen"|"apparel"|"towel"|"mop"|"other","color_hex"?: string,"count_mode"?: "unit"|"pack","created_at"?: string,"id"?: string,"name"?: string,"name_i18n"?: NonNullable<Json>,"org_id"?: string,"pack_size"?: number | null,"pieces_per_load"?: number | null,"pieces_per_load_source"?: string | null,"plant_id"?: string,"sort_order"?: number,"updated_at"?: string,"wash_group_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "item_types_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "item_types_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"languages": {
                  Row: {
                    "code": string,"name_native": string,"rtl": boolean,"speech_recognition_tested": boolean,"ui_ready": boolean
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"name_native": string,"rtl"?: boolean,"speech_recognition_tested"?: boolean,"ui_ready"?: boolean
                  }
                  Update: {
                    "code"?: string,"name_native"?: string,"rtl"?: boolean,"speech_recognition_tested"?: boolean,"ui_ready"?: boolean
                  }
                  Relationships: [
                    
                  ]
                },"machines": {
                  Row: {
                    "active": boolean,"area_id": string,"created_at": string,"external_ref": string | null,"id": string,"kind": "washer"|"dryer"|"ironer"|"folder"|"other","load_factor": number,"model": string | null,"name": string,"org_id": string,"plant_id": string,"vendor": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"area_id": string,"created_at"?: string,"external_ref"?: string | null,"id"?: string,"kind": "washer"|"dryer"|"ironer"|"folder"|"other","load_factor"?: number,"model"?: string | null,"name": string,"org_id": string,"plant_id": string,"vendor"?: string | null
                  }
                  Update: {
                    "active"?: boolean,"area_id"?: string,"created_at"?: string,"external_ref"?: string | null,"id"?: string,"kind"?: "washer"|"dryer"|"ironer"|"folder"|"other","load_factor"?: number,"model"?: string | null,"name"?: string,"org_id"?: string,"plant_id"?: string,"vendor"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "machines_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "machines_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"memberships": {
                  Row: {
                    "can_manage_staff": boolean,"created_at": string,"id": string,"org_id": string,"plant_id": string | null,"revoked_at": string | null,"role": "owner"|"manager"|"lead"|"viewer"|"display","user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "can_manage_staff"?: boolean,"created_at"?: string,"id"?: string,"org_id": string,"plant_id"?: string | null,"revoked_at"?: string | null,"role": "owner"|"manager"|"lead"|"viewer"|"display","user_id": string
                  }
                  Update: {
                    "can_manage_staff"?: boolean,"created_at"?: string,"id"?: string,"org_id"?: string,"plant_id"?: string | null,"revoked_at"?: string | null,"role"?: "owner"|"manager"|"lead"|"viewer"|"display","user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "memberships_org_id_fkey"
      columns: ["org_id"]
isOneToOne: false
      referencedRelation: "organizations"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "memberships_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"organizations": {
                  Row: {
                    "created_at": string,"id": string,"name": string,"slug": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"name": string,"slug": string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"name"?: string,"slug"?: string
                  }
                  Relationships: [
                    
                  ]
                },"pairing_codes": {
                  Row: {
                    "area_id": string,"code": string,"consumed_at": string | null,"created_by": string,"device_name": string,"expires_at": string,"org_id": string,"plant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"code": string,"consumed_at"?: string | null,"created_by": string,"device_name": string,"expires_at": string,"org_id": string,"plant_id": string
                  }
                  Update: {
                    "area_id"?: string,"code"?: string,"consumed_at"?: string | null,"created_by"?: string,"device_name"?: string,"expires_at"?: string,"org_id"?: string,"plant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "pairing_codes_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "pairing_codes_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"plants": {
                  Row: {
                    "created_at": string,"default_language": string,"display_reload_local_time": string,"enabled_languages": (string)[],"estimate_amber_minutes": number,"estimate_red_minutes": number,"id": string,"name": string,"org_id": string,"production_day_start": string,"staff_pin_reuse_minutes": number,"timezone": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"default_language"?: string,"display_reload_local_time"?: string,"enabled_languages"?: (string)[],"estimate_amber_minutes"?: number,"estimate_red_minutes"?: number,"id"?: string,"name": string,"org_id": string,"production_day_start"?: string,"staff_pin_reuse_minutes"?: number,"timezone"?: string
                  }
                  Update: {
                    "created_at"?: string,"default_language"?: string,"display_reload_local_time"?: string,"enabled_languages"?: (string)[],"estimate_amber_minutes"?: number,"estimate_red_minutes"?: number,"id"?: string,"name"?: string,"org_id"?: string,"production_day_start"?: string,"staff_pin_reuse_minutes"?: number,"timezone"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "plants_default_language_fkey"
      columns: ["default_language"]
isOneToOne: false
      referencedRelation: "languages"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "plants_org_id_fkey"
      columns: ["org_id"]
isOneToOne: false
      referencedRelation: "organizations"
      referencedColumns: ["id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "a11y_prefs": NonNullable<Json>,"created_at": string,"full_name": string | null,"language": string,"notify_email": boolean,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "a11y_prefs"?: NonNullable<Json>,"created_at"?: string,"full_name"?: string | null,"language"?: string,"notify_email"?: boolean,"user_id": string
                  }
                  Update: {
                    "a11y_prefs"?: NonNullable<Json>,"created_at"?: string,"full_name"?: string | null,"language"?: string,"notify_email"?: boolean,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "profiles_language_fkey"
      columns: ["language"]
isOneToOne: false
      referencedRelation: "languages"
      referencedColumns: ["code"]
    }
                  ]
                },"queue_items": {
                  Row: {
                    "area_id": string,"assigned_machine_id": string | null,"assigned_machine_kind": "washer"|"dryer"|"ironer"|"folder"|"other" | null,"client_id": string,"completed_at": string | null,"created_at": string,"created_by": string,"id": string,"is_rewash": boolean,"is_rush": boolean,"item_type_id": string | null,"note": string | null,"org_id": string,"plant_id": string,"position": number,"qty": number,"started_at": string | null,"status": "queued"|"in_progress"|"done"|"cancelled","unit": "load"|"basket"|"piece"|"pack","updated_at": string,"updated_by": string | null,"updated_by_staff_id": string | null,"version": number,"wash_group_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"assigned_machine_id"?: string | null,"assigned_machine_kind"?: never,"client_id": string,"completed_at"?: string | null,"created_at"?: string,"created_by": string,"id"?: string,"is_rewash"?: boolean,"is_rush"?: boolean,"item_type_id"?: string | null,"note"?: string | null,"org_id": string,"plant_id": string,"position": number,"qty": number,"started_at"?: string | null,"status"?: "queued"|"in_progress"|"done"|"cancelled","unit": "load"|"basket"|"piece"|"pack","updated_at"?: string,"updated_by"?: string | null,"updated_by_staff_id"?: string | null,"version"?: number,"wash_group_id": string
                  }
                  Update: {
                    "area_id"?: string,"assigned_machine_id"?: string | null,"assigned_machine_kind"?: never,"client_id"?: string,"completed_at"?: string | null,"created_at"?: string,"created_by"?: string,"id"?: string,"is_rewash"?: boolean,"is_rush"?: boolean,"item_type_id"?: string | null,"note"?: string | null,"org_id"?: string,"plant_id"?: string,"position"?: number,"qty"?: number,"started_at"?: string | null,"status"?: "queued"|"in_progress"|"done"|"cancelled","unit"?: "load"|"basket"|"piece"|"pack","updated_at"?: string,"updated_by"?: string | null,"updated_by_staff_id"?: string | null,"version"?: number,"wash_group_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "queue_items_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_assigned_washer_fkey"
      columns: ["assigned_machine_id","area_id","assigned_machine_kind"]
isOneToOne: false
      referencedRelation: "machines"
      referencedColumns: ["id","area_id","kind"]
    },{
      foreignKeyName: "queue_items_item_type_id_plant_id_fkey"
      columns: ["item_type_id","plant_id"]
isOneToOne: false
      referencedRelation: "item_types"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "queue_items_updated_by_staff_id_plant_id_fkey"
      columns: ["updated_by_staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_updated_by_staff_id_plant_id_fkey"
      columns: ["updated_by_staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"shift_crew_hours": {
                  Row: {
                    "area_id": string,"crew_count": number,"entered_at": string,"entered_by": string,"id": string,"labor_hours": number,"org_id": string,"plant_id": string,"shift_instance_id": string,"staff_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"crew_count": number,"entered_at"?: string,"entered_by": string,"id"?: string,"labor_hours": number,"org_id": string,"plant_id": string,"shift_instance_id": string,"staff_id"?: string | null
                  }
                  Update: {
                    "area_id"?: string,"crew_count"?: number,"entered_at"?: string,"entered_by"?: string,"id"?: string,"labor_hours"?: number,"org_id"?: string,"plant_id"?: string,"shift_instance_id"?: string,"staff_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "shift_crew_hours_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "shift_crew_hours_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "shift_crew_hours_shift_instance_id_area_id_fkey"
      columns: ["shift_instance_id","area_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "shift_crew_hours_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "shift_crew_hours_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"shift_instances": {
                  Row: {
                    "area_id": string,"business_date": string,"ends_at": string,"id": string,"org_id": string,"plant_id": string,"production_date": string,"shift_id": string,"skipped_at": string | null,"starts_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"business_date": string,"ends_at": string,"id"?: string,"org_id": string,"plant_id": string,"production_date": string,"shift_id": string,"skipped_at"?: string | null,"starts_at": string
                  }
                  Update: {
                    "area_id"?: string,"business_date"?: string,"ends_at"?: string,"id"?: string,"org_id"?: string,"plant_id"?: string,"production_date"?: string,"shift_id"?: string,"skipped_at"?: string | null,"starts_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "shift_instances_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "shift_instances_shift_id_area_id_fkey"
      columns: ["shift_id","area_id"]
isOneToOne: false
      referencedRelation: "shifts"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "shift_instances_shift_id_plant_id_fkey"
      columns: ["shift_id","plant_id"]
isOneToOne: false
      referencedRelation: "shifts"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"shifts": {
                  Row: {
                    "active": boolean,"area_id": string,"created_at": string,"days_of_week": (number)[],"end_local": string,"id": string,"name": string,"org_id": string,"plant_id": string,"start_local": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"area_id": string,"created_at"?: string,"days_of_week": (number)[],"end_local": string,"id"?: string,"name": string,"org_id": string,"plant_id": string,"start_local": string
                  }
                  Update: {
                    "active"?: boolean,"area_id"?: string,"created_at"?: string,"days_of_week"?: (number)[],"end_local"?: string,"id"?: string,"name"?: string,"org_id"?: string,"plant_id"?: string,"start_local"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "shifts_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "shifts_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"soil_estimates": {
                  Row: {
                    "client_id": string,"entered_at": string,"entered_by": string,"id": string,"note": string | null,"org_id": string,"plant_id": string,"qty": number,"staff_id": string | null,"unit": "load"|"basket"|"piece"|"pack","wash_group_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "client_id": string,"entered_at"?: string,"entered_by": string,"id"?: string,"note"?: string | null,"org_id": string,"plant_id": string,"qty": number,"staff_id"?: string | null,"unit": "load"|"basket"|"piece"|"pack","wash_group_id": string
                  }
                  Update: {
                    "client_id"?: string,"entered_at"?: string,"entered_by"?: string,"id"?: string,"note"?: string | null,"org_id"?: string,"plant_id"?: string,"qty"?: number,"staff_id"?: string | null,"unit"?: "load"|"basket"|"piece"|"pack","wash_group_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "soil_estimates_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "soil_estimates_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "soil_estimates_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "soil_estimates_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"staff_sessions": {
                  Row: {
                    "auth_user_id": string,"confirmed_at": string,"consumed_at": string | null,"expires_at": string,"id": string,"org_id": string,"plant_id": string,"staff_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "auth_user_id": string,"confirmed_at"?: string,"consumed_at"?: string | null,"expires_at": string,"id"?: string,"org_id": string,"plant_id": string,"staff_id": string
                  }
                  Update: {
                    "auth_user_id"?: string,"confirmed_at"?: string,"consumed_at"?: string | null,"expires_at"?: string,"id"?: string,"org_id"?: string,"plant_id"?: string,"staff_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "staff_sessions_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "staff_sessions_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "staff_sessions_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"stations": {
                  Row: {
                    "active": boolean,"area_id": string,"created_at": string,"id": string,"kind": "ironer"|"folder"|"mat_roller"|"packing"|"washroom"|"other","name": string,"org_id": string,"plant_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"area_id": string,"created_at"?: string,"id"?: string,"kind": "ironer"|"folder"|"mat_roller"|"packing"|"washroom"|"other","name": string,"org_id": string,"plant_id": string
                  }
                  Update: {
                    "active"?: boolean,"area_id"?: string,"created_at"?: string,"id"?: string,"kind"?: "ironer"|"folder"|"mat_roller"|"packing"|"washroom"|"other","name"?: string,"org_id"?: string,"plant_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "stations_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "stations_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"wash_formulas": {
                  Row: {
                    "created_at": string,"cycle_minutes": number | null,"external_no": string,"id": string,"name": string | null,"org_id": string,"plant_id": string,"wash_group_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"cycle_minutes"?: number | null,"external_no": string,"id"?: string,"name"?: string | null,"org_id": string,"plant_id": string,"wash_group_id"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"cycle_minutes"?: number | null,"external_no"?: string,"id"?: string,"name"?: string | null,"org_id"?: string,"plant_id"?: string,"wash_group_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "wash_formulas_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "wash_formulas_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"wash_groups": {
                  Row: {
                    "active": boolean,"allow_basket_estimates": boolean,"baskets_per_load": number | null,"color_hex": string,"created_at": string,"default_estimate_unit": "load"|"basket"|"piece"|"pack","id": string,"name": string,"name_i18n": NonNullable<Json>,"org_id": string,"plant_id": string,"sort_order": number,"updated_at": string,"wash_formula_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"allow_basket_estimates"?: boolean,"baskets_per_load"?: number | null,"color_hex"?: string,"created_at"?: string,"default_estimate_unit"?: "load"|"basket"|"piece"|"pack","id"?: string,"name": string,"name_i18n"?: NonNullable<Json>,"org_id": string,"plant_id": string,"sort_order"?: number,"updated_at"?: string,"wash_formula_id"?: string | null
                  }
                  Update: {
                    "active"?: boolean,"allow_basket_estimates"?: boolean,"baskets_per_load"?: number | null,"color_hex"?: string,"created_at"?: string,"default_estimate_unit"?: "load"|"basket"|"piece"|"pack","id"?: string,"name"?: string,"name_i18n"?: NonNullable<Json>,"org_id"?: string,"plant_id"?: string,"sort_order"?: number,"updated_at"?: string,"wash_formula_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "wash_groups_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "wash_groups_wash_formula_fkey"
      columns: ["wash_formula_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_formulas"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"washer_cycles": {
                  Row: {
                    "area_id": string,"client_id": string | null,"created_at": string,"ended_at": string | null,"entered_by": string | null,"external_id": string | null,"id": string,"import_batch_id": string | null,"is_rewash": boolean,"load_count": number,"load_factor_used": number,"machine_id": string | null,"org_id": string,"plant_id": string,"raw": Json | null,"shift_instance_id": string | null,"source": "manual"|"accuflow_csv"|"accuflow_api","staff_id": string | null,"started_at": string,"wash_formula_id": string | null,"wash_group_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "area_id": string,"client_id"?: string | null,"created_at"?: string,"ended_at"?: string | null,"entered_by"?: string | null,"external_id"?: string | null,"id"?: string,"import_batch_id"?: string | null,"is_rewash"?: boolean,"load_count"?: number,"load_factor_used": number,"machine_id"?: string | null,"org_id": string,"plant_id": string,"raw"?: Json | null,"shift_instance_id"?: string | null,"source": "manual"|"accuflow_csv"|"accuflow_api","staff_id"?: string | null,"started_at": string,"wash_formula_id"?: string | null,"wash_group_id"?: string | null
                  }
                  Update: {
                    "area_id"?: string,"client_id"?: string | null,"created_at"?: string,"ended_at"?: string | null,"entered_by"?: string | null,"external_id"?: string | null,"id"?: string,"import_batch_id"?: string | null,"is_rewash"?: boolean,"load_count"?: number,"load_factor_used"?: number,"machine_id"?: string | null,"org_id"?: string,"plant_id"?: string,"raw"?: Json | null,"shift_instance_id"?: string | null,"source"?: "manual"|"accuflow_csv"|"accuflow_api","staff_id"?: string | null,"started_at"?: string,"wash_formula_id"?: string | null,"wash_group_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "washer_cycles_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_import_batch_id_plant_id_fkey"
      columns: ["import_batch_id","plant_id"]
isOneToOne: false
      referencedRelation: "import_batches"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_machine_id_plant_id_fkey"
      columns: ["machine_id","plant_id"]
isOneToOne: false
      referencedRelation: "machines"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "washer_cycles_shift_instance_id_area_id_fkey"
      columns: ["shift_instance_id","area_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "washer_cycles_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_wash_formula_id_plant_id_fkey"
      columns: ["wash_formula_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_formulas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                }
          }
          Views: {
            "current_soil_estimates": {
                  Row: {
                    "age_minutes": number | null,"entered_at": string,"entered_by": string,"entered_by_name": string | null,"estimate_id": string,"freshness": string | null,"has_conversion": boolean | null,"org_id": string,"plant_id": string,"qty": number,"qty_loads": number | null,"staff_id": string | null,"unit": "load"|"basket"|"piece"|"pack","wash_group_id": string,"wash_group_name": string,"wash_group_name_i18n": NonNullable<Json>
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "soil_estimates_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "soil_estimates_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "soil_estimates_staff_id_plant_id_fkey"
      columns: ["staff_id","plant_id"]
isOneToOne: false
      referencedRelation: "entry_staff_public"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "soil_estimates_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"daily_reconciliation": {
                  Row: {
                    "approximate": boolean | null,"clean_backlog_loads_approx": number | null,"est_loads_end": number | null,"est_loads_start": number | null,"estimate_error_pct": number | null,"finished_incomplete": boolean | null,"items_finished": number | null,"loads_finished_approx": number | null,"loads_finished_partial_approx": number | null,"loads_run": number | null,"org_id": string | null,"pieces_finished": number | null,"pieces_without_conversion": number | null,"plant_id": string | null,"production_date": string | null,"rewash_loads": number | null,"standard_loads": number | null,"wash_group_id": string | null,"wash_group_name": string,"wash_group_name_i18n": NonNullable<Json>
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"entry_staff_public": {
                  Row: {
                    "active": boolean,"created_at": string,"display_name": string,"has_pin": boolean | null,"home_shift_id": string | null,"id": string,"language": string,"org_id": string,"plant_id": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                           "active"?: boolean | null,"created_at"?: string | null,"display_name"?: string | null,"has_pin"?: boolean | null,"home_shift_id"?: string | null,"id"?: string | null,"language"?: string | null,"org_id"?: string | null,"plant_id"?: string | null,"updated_at"?: string | null
                         }
                        Update: {
                           "active"?: boolean | null,"created_at"?: string | null,"display_name"?: string | null,"has_pin"?: boolean | null,"home_shift_id"?: string | null,"id"?: string | null,"language"?: string | null,"org_id"?: string | null,"plant_id"?: string | null,"updated_at"?: string | null
                         }
                        Relationships: [
                    {
      foreignKeyName: "entry_staff_home_shift_id_plant_id_fkey"
      columns: ["home_shift_id","plant_id"]
isOneToOne: false
      referencedRelation: "shifts"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "entry_staff_language_fkey"
      columns: ["language"]
isOneToOne: false
      referencedRelation: "languages"
      referencedColumns: ["code"]
    },{
      foreignKeyName: "entry_staff_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    }
                  ]
                },"finished_by_shift": {
                  Row: {
                    "approximate": boolean | null,"area_id": string,"has_conversion": boolean | null,"item_type_id": string,"loads_approx": number | null,"loose_pieces": number | null,"org_id": string,"packs": number | null,"pieces": number | null,"plant_id": string,"production_date": string | null,"shift_instance_id": string | null,"station_id": string | null,"wash_group_id": string
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "finished_goods_entries_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_item_type_id_plant_id_fkey"
      columns: ["item_type_id","plant_id"]
isOneToOne: false
      referencedRelation: "item_types"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "finished_goods_entries_shift_instance_id_area_id_fkey"
      columns: ["shift_instance_id","area_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "finished_goods_entries_station_id_plant_id_fkey"
      columns: ["station_id","plant_id"]
isOneToOne: false
      referencedRelation: "stations"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "finished_goods_entries_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"queue_board": {
                  Row: {
                    "approximate": boolean | null,"area_id": string,"assigned_machine_id": string | null,"assigned_machine_name": string | null,"created_at": string,"id": string,"is_rewash": boolean,"is_rush": boolean,"item_color_hex": string | null,"item_name": string | null,"item_name_i18n": Json | null,"item_type_id": string | null,"note": string | null,"org_id": string,"plant_id": string,"position": number,"qty": number,"qty_loads": number | null,"started_at": string | null,"status": "queued"|"in_progress"|"done"|"cancelled","unit": "load"|"basket"|"piece"|"pack","version": number,"wash_group_color_hex": string,"wash_group_id": string,"wash_group_name": string,"wash_group_name_i18n": NonNullable<Json>
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "queue_items_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_item_type_id_plant_id_fkey"
      columns: ["item_type_id","plant_id"]
isOneToOne: false
      referencedRelation: "item_types"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "queue_items_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "queue_items_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                },"washroom_by_shift": {
                  Row: {
                    "approximate": boolean | null,"area_id": string,"loads_run": number | null,"org_id": string,"plant_id": string,"production_date": string | null,"rewash_loads": number | null,"shift_instance_id": string | null,"standard_loads": number | null,"wash_group_id": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "washer_cycles_area_id_plant_id_fkey"
      columns: ["area_id","plant_id"]
isOneToOne: false
      referencedRelation: "areas"
      referencedColumns: ["id","plant_id"]
    },{
      foreignKeyName: "washer_cycles_plant_id_org_id_fkey"
      columns: ["plant_id","org_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id","org_id"]
    },{
      foreignKeyName: "washer_cycles_shift_instance_id_area_id_fkey"
      columns: ["shift_instance_id","area_id"]
isOneToOne: false
      referencedRelation: "shift_instances"
      referencedColumns: ["id","area_id"]
    },{
      foreignKeyName: "washer_cycles_wash_group_id_plant_id_fkey"
      columns: ["wash_group_id","plant_id"]
isOneToOne: false
      referencedRelation: "wash_groups"
      referencedColumns: ["id","plant_id"]
    }
                  ]
                }
          }
          Functions: {
            "create_pairing_code":
{ Args: { "p_area_id": string,"p_device_name": string }; Returns: Database["public"]['CompositeTypes']["pairing_code_result"]
                          SetofOptions: {
        from: "*"
        to: "pairing_code_result"
        isOneToOne: true
        isSetofReturn: false
      } },
"set_shift_skipped":
{ Args: { "p_shift_instance_id": string,"p_skipped": boolean }; Returns: {
              "area_id": string,
"business_date": string,
"ends_at": string,
"id": string,
"org_id": string,
"plant_id": string,
"production_date": string,
"shift_id": string,
"skipped_at": string | null,
"starts_at": string
            }
                          SetofOptions: {
        from: "*"
        to: "shift_instances"
        isOneToOne: true
        isSetofReturn: false
      } },
"set_staff_pin":
{ Args: { "p_pin": string,"p_staff_id": string }; Returns: undefined
                           },
"start_staff_session":
{ Args: { "p_pin": string,"p_staff_id": string }; Returns: Database["public"]['CompositeTypes']["staff_session_result"]
                          SetofOptions: {
        from: "*"
        to: "staff_session_result"
        isOneToOne: true
        isSetofReturn: false
      } }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            "pairing_code_result": {
                        "code": string | null,"expires_at": string | null
                      },"staff_session_result": {
                        "staff_session_id": string | null,"error": string | null,"locked_until": string | null
                      }
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            
          }
        }
} as const
