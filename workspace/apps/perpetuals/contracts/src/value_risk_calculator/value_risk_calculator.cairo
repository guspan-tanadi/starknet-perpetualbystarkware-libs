#[starknet::contract]
pub mod ValueRiskCalculator {
    use contracts_commons::math::Abs;
    use contracts_commons::types::fixed_two_decimal::{FixedTwoDecimal, FixedTwoDecimalTrait};
    use perpetuals::core::types::asset::AssetId;
    use perpetuals::core::types::{PositionData, PositionDiff};
    use perpetuals::value_risk_calculator::interface::{IValueRiskCalculator, PositionState};
    use perpetuals::value_risk_calculator::interface::{PositionChangeResult, PositionTVTR};
    use perpetuals::value_risk_calculator::interface::{PositionTVTRChange, changeEffects};
    use starknet::storage::Map;


    #[storage]
    struct Storage {
        risk_factors: Map<AssetId, FixedTwoDecimal>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[constructor]
    pub fn constructor(ref self: ContractState) {}


    #[abi(embed_v0)]
    pub impl ValueRiskCalculatorImpl of IValueRiskCalculator<ContractState> {
        fn evaluate_position_change(
            self: @ContractState, position: PositionData, position_diff: PositionDiff,
        ) -> PositionChangeResult {
            PositionChangeResult {
                position_state_before_change: PositionState::Healthy,
                position_state_after_change: PositionState::Healthy,
                change_effects: changeEffects { is_healthier: true, is_fair_deleverage: true },
            }
        }
        fn set_risk_factor_for_asset(
            ref self: ContractState, asset_id: AssetId, risk_factor: FixedTwoDecimal,
        ) {
            self.risk_factors.write(asset_id, risk_factor);
        }
        fn calculate_position_tvtr_change(
            self: @ContractState, position: PositionData, position_diff: PositionDiff,
        ) -> PositionTVTRChange {
            // Calculate the total value and total risk before the diff.
            let mut total_value_before = 0_i128;
            let mut total_risk_before = 0_u128;
            let asset_entries = position.asset_entries;
            for asset_entry in asset_entries {
                let balance = *asset_entry.balance.value;
                let price = *asset_entry.price;
                let asset_id = *asset_entry.id;
                let risk_factor = self.risk_factors.read(asset_id);
                let asset_value = balance * price.into();

                // Update the total value and total risk.
                total_value_before += asset_value;
                total_risk_before += risk_factor.mul(asset_value.abs());
            };

            // Calculate the total value and total risk after the diff.
            let mut total_value_after = total_value_before;
            let mut total_risk_after: i128 = total_risk_before.try_into().unwrap();
            for asset_diff_entry in position_diff {
                let asset_id = *asset_diff_entry.id;
                let risk_factor = self.risk_factors.read(asset_id);
                let price = *asset_diff_entry.price;
                let balance_before = *asset_diff_entry.before.value;
                let balance_after = *asset_diff_entry.after.value;
                let asset_value_before = balance_before * price.into();
                let asset_value_after = balance_after * price.into();

                /// Update the total value.
                total_value_after += asset_value_after;
                total_value_after -= asset_value_before;

                /// Update the total risk.
                total_risk_after += risk_factor.mul(asset_value_after.abs()).try_into().unwrap();
                total_risk_after -= risk_factor.mul(asset_value_before.abs()).try_into().unwrap();
            };

            // Return the total value and total risk before and after the diff.
            PositionTVTRChange {
                before: PositionTVTR {
                    total_value: total_value_before, total_risk: total_risk_before,
                },
                after: PositionTVTR {
                    total_value: total_value_after,
                    total_risk: total_risk_after.try_into().unwrap(),
                },
            }
        }
    }
}
