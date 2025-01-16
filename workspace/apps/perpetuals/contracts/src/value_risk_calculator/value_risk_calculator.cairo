#[starknet::contract]
pub mod ValueRiskCalculator {
    use contracts_commons::math::{Abs, FractionTrait};
    use contracts_commons::types::fixed_two_decimal::FixedTwoDecimalTrait;
    use perpetuals::core::types::price::PriceMulTrait;
    use perpetuals::core::types::{PositionData, PositionDiff};
    use perpetuals::value_risk_calculator::interface::{
        ChangeEffects, IValueRiskCalculator, PositionChangeResult, PositionStateTrait, PositionTVTR,
        PositionTVTRChange,
    };


    #[storage]
    struct Storage {}

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[constructor]
    pub fn constructor(ref self: ContractState) {}

    /// The position is fair if the total_value divided by the total_risk is the same
    /// before and after the change.
    fn is_fair_deleverage(before: PositionTVTR, after: PositionTVTR) -> bool {
        let before_ratio = FractionTrait::new(before.total_value, before.total_risk);
        let after_ratio = FractionTrait::new(after.total_value, after.total_risk);
        before_ratio == after_ratio
    }

    /// The position is healthier if the total_value divided by the total_risk
    /// is higher after the change and the total_risk is lower.
    /// Formal definition:
    /// total_value_after / total_risk_after > total_value_before / total_risk_before
    /// AND total_risk_after < total_risk_before.
    fn is_healthier(before: PositionTVTR, after: PositionTVTR) -> bool {
        let before_ratio = FractionTrait::new(before.total_value, before.total_risk);
        let after_ratio = FractionTrait::new(after.total_value, after.total_risk);
        after_ratio >= before_ratio && after.total_risk < before.total_risk
    }


    #[abi(embed_v0)]
    pub impl ValueRiskCalculatorImpl of IValueRiskCalculator<ContractState> {
        fn evaluate_position_change(
            self: @ContractState, position: PositionData, position_diff: PositionDiff,
        ) -> PositionChangeResult {
            let tvtr = self.calculate_position_tvtr_change(position, position_diff);

            let change_effects = if tvtr.before.total_risk != 0 && tvtr.after.total_risk != 0 {
                Option::Some(
                    ChangeEffects {
                        is_healthier: is_healthier(tvtr.before, tvtr.after),
                        is_fair_deleverage: is_fair_deleverage(tvtr.before, tvtr.after),
                    },
                )
            } else {
                Option::None
            };
            PositionChangeResult {
                position_state_before_change: PositionStateTrait::new(tvtr.before),
                position_state_after_change: PositionStateTrait::new(tvtr.after),
                change_effects,
            }
        }
    }

    #[generate_trait]
    pub impl InternalValueRiskCalculatorFunctions of InternalValueRiskCalculatorFunctionsTrait {
        fn calculate_position_tvtr_change(
            self: @ContractState, position: PositionData, position_diff: PositionDiff,
        ) -> PositionTVTRChange {
            // Calculate the total value and total risk before the diff.
            let mut total_value_before = 0_i128;
            let mut total_risk_before = 0_u128;
            let asset_entries = position.asset_entries;
            for asset_entry in asset_entries {
                let balance = *asset_entry.balance;
                let price = *asset_entry.price;
                let risk_factor = *asset_entry.risk_factor;
                let asset_value: i128 = price.mul(rhs: balance);

                // Update the total value and total risk.
                total_value_before += asset_value;
                total_risk_before += risk_factor.mul(asset_value.abs());
            };

            // Calculate the total value and total risk after the diff.
            let mut total_value_after = total_value_before;
            let mut total_risk_after: u128 = total_risk_before;
            for asset_diff_entry in position_diff {
                let risk_factor = *asset_diff_entry.risk_factor;
                let price = *asset_diff_entry.price;
                let balance_before = *asset_diff_entry.before;
                let balance_after = *asset_diff_entry.after;
                let asset_value_before = price.mul(rhs: balance_before);
                let asset_value_after = price.mul(rhs: balance_after);

                /// Update the total value.
                total_value_after += asset_value_after;
                total_value_after -= asset_value_before;

                /// Update the total risk.
                total_risk_after += risk_factor.mul(asset_value_after.abs());
                total_risk_after -= risk_factor.mul(asset_value_before.abs());
            };

            // Return the total value and total risk before and after the diff.
            PositionTVTRChange {
                before: PositionTVTR {
                    total_value: total_value_before, total_risk: total_risk_before,
                },
                after: PositionTVTR {
                    total_value: total_value_after, total_risk: total_risk_after,
                },
            }
        }
    }
}
