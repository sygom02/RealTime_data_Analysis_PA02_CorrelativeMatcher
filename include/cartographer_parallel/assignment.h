#ifndef CARTOGRAPHER_PARALLEL_ASSIGNMENT_H_
#define CARTOGRAPHER_PARALLEL_ASSIGNMENT_H_

#include <vector>

namespace cartographer_parallel {

void make_cand(int min_x, int max_x, int min_y, int max_y, int step,
               std::vector<int>* cx, std::vector<int>* cy);

void score_all(const std::vector<unsigned char>& grid, int w, int h,
               const std::vector<int>& px, const std::vector<int>& py,
               const std::vector<int>& cx, const std::vector<int>& cy,
               std::vector<float>* score);

void score_all_batched(const std::vector<unsigned char>& grid, int w, int h,
                       const std::vector<int>& scan_x_flat,
                       const std::vector<int>& scan_y_flat,
                       const std::vector<int>& scan_offsets,
                       const std::vector<int>& scan_sizes,
                       const std::vector<int>& cand_scan,
                       const std::vector<int>& cand_x,
                       const std::vector<int>& cand_y,
                       std::vector<float>* score);

}  // namespace cartographer_parallel

#endif  // CARTOGRAPHER_PARALLEL_ASSIGNMENT_H_
